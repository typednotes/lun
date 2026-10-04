/-
  LunDriver.Runtime — written by lun into every driver package; do not edit.

  A *driver* is the Lake package lun generates around a user project: one
  module per declared function, one per declared graph, and an executable serving
  them over a stdin/stdout JSON protocol. This module is everything those
  generated modules share:

  - `FunctionType σ` — which types a served function can have, and how to call one on JSON
    arguments: `α₁ → … → αₙ → Eff effs β` with every `αᵢ` `Lean.FromJson`, `β`
    `Lean.ToJson`, and `effs` runnable in the bound `Execution` monad
    (`Handlers effs Execution`). A `Unit`
    argument takes no input.
  - `lun_function "name" := f : r"σ"` — the signature check, stricter than
    elaboration:
    `f` must *be* a function of type `σ` (no coercion), non-dependent, ending in
    `Eff`, whose effects are all vetted ones — `Trace`, `Error`, `HTTP`,
    `FileSystem`, `Connector`, `PostgreSQL`, `SecretStore`, `ObjectStore` —
    interpreted by canonical context-bound handlers (a project's own handler
    instance is refused), and free of `sorry`; then the
    function's implementation and typed reference.
  - `ProducerType σ` / `lun_producer` — resumable steps with ordinary graph
    arguments followed by `Nat → Option S → Eff effs (List B × S × Option Nat)`.
    The clock and continuation are supplied by the executor; each `B` is an
    observable emission, not the whole step envelope. The same audit applies.
  - `lun_graph "name" := r#"program"#` — a graph: a program in linen's
    `Reactive IO Json` monad (`Control.Reactive`) over `input`s and the functions,
    each function applying to observables (a `combineLatest` over
    the function). The check: the program is free of `sorry` and of the builder's
    primitives (it is walked through every non-library constant it uses), and
    the graph it builds consists of inputs and applications of declared functions
    with their arity, nothing else (`GraphImpl.ofGraph`). Every function of the
    graph is then replaced by the declared function its label names, so what runs
    is only ever a declared, checked function.
  - Request text (signatures, graph programs) is embedded as raw string literals
    and parsed as exactly one term each (`parseEmbeddedTerm`), so it can never
    add commands to a generated module; messages still point into it.
  - `driverMain` — the executable's protocol (see its doc comment).
  - `GraphState` / `runGraph` — stateless topological execution. The caller
    supplies and persists state, receives every changed outcome and a next-call
    timestamp, and schedules wake-ups. Warm workers retain code, never state.
-/
import Lean
import Linen.Control.Reactive
import Linen.Control.Monad.Effect.Handler
import Linen.Control.Monad.Effect.Trace
import Linen.Control.Monad.Effect.Error
import Linen.Control.Monad.Effect.HTTP
import Linen.Control.Monad.Effect.FileSystem
import Linen.Control.Monad.Effect.Connector
import Linen.Control.Monad.Effect.PostgreSQL
import Linen.Control.Monad.Effect.SecretStore
import Linen.Control.Monad.Effect.ObjectStore
import Liaison.Wire
import Linen.Data.Json.Bridge
import Linen.Network.HTTP.Simple
import Linen.Data.Time.ISO8601
import Linen.System.Process
import Linen.Data.Hex
import Linen.Text.XML

namespace LunDriver

def runtimeContract : String := "stateless-producers-v4"

open Lean Control.Monad.Effect Control.Reactive

open Elab Command in
elab "lun_trusted_imports" : command => do
  let modules := Lean.quote (← getEnv).header.moduleNames.toList
  elabCommand (← `(def $(mkIdent `_root_.LunDriver.trustedImports) : List Name := $modules))

set_option maxRecDepth 10000 in
lun_trusted_imports

def trustedImportSet : NameSet := trustedImports.foldl (fun names name => names.insert name) {}

/-- Exact modules imported by the driver runtime, not a spoofable namespace
    prefix. Project code called Linen.Evil remains project code. -/
def trustedModule (m : Name) : Bool := trustedImportSet.contains m || m == `LunDriver.Runtime

-- ── Caller-owned execution bounds ──────────────────────────────────────────

/-- Per-request diagnostics have a kernel-checked byte ceiling. The IO reference
    is fresh for each frame, never stored in a graph or a worker cache. -/
structure BoundedTrace where
  private mk ::
  value : String
  bounded : value.utf8ByteSize ≤ 1024 * 1024

def emptyTrace : BoundedTrace := ⟨"", by decide⟩

/-- Runtime upper bounds are supplied by the authenticated app, never by code
    compiled from a notebook. A build may permanently require these bounds. -/
structure ExecutionContext where
  effects : Option (List String) := some []
  domains : List String := []
  org : String := ""
  user : String := ""
  schema : String := ""
  graph : String := ""
  functionName : String := ""
  connectors : Json := Json.mkObj []
  liaisonUrl : Option String := none
  /-- Server-owned private stdin context, never exposed to an effect value. -/
  runtime : Json := Json.mkObj []
  traceLog : Option (IO.Ref BoundedTrace) := none

abbrev Execution := ReaderT ExecutionContext IO

def ExecutionContext.ofRequest (req : Json) (traceLog : Option (IO.Ref BoundedTrace) := none) : Except String ExecutionContext := do
  match req.getObjVal? "policy" with
  | .error _ => return {traceLog}
  | .ok policy =>
    let effects ← policy.getObjValAs? (List String) "effects"
    let domains ← policy.getObjValAs? (List String) "domains"
    let binding ← req.getObjVal? "binding"
    let org ← binding.getObjValAs? String "org_id"
    let user ← binding.getObjValAs? String "user_id"
    let plain (s : String) := !s.isEmpty && s.all (fun c => c.isAlphanum || c == '-' || c == '_')
    unless plain org && plain user do throw "invalid organization/user binding"
    return { effects := some effects, domains := domains, org := org, user := user,
              schema := (binding.getObjValAs? String "schema").toOption.getD "",
              graph := (binding.getObjValAs? String "graph_id").toOption.getD "",
              connectors := (req.getObjVal? "connectors").toOption.getD (Json.mkObj []),
              liaisonUrl := (req.getObjValAs? String "liaisonUrl").toOption,
              runtime := (req.getObjVal? "_runtime").toOption.getD (Json.mkObj []), traceLog }

/-- Every interpreter entry consumes permission from the current request. -/
structure EffectPermission (ctx : ExecutionContext) (name : String) : Type where
  permitted : (ctx.effects.getD []).contains name = true

def requireEffect (ctx : ExecutionContext) (name : String) : IO (EffectPermission ctx name) := do
  if h : (ctx.effects.getD []).contains name = true then return ⟨h⟩
  else throw (IO.userError s!"organization permission denied: {name}")

instance instExecutionTrace : Handler Trace.Trace Execution where
  handle
    | .trace message => fun ctx => do
      let _permission ← requireEffect ctx "Trace"
      match ctx.traceLog with
      | none => IO.eprintln message
      | some log =>
        let previous ← log.get
        let value := previous.value ++ message ++ "\n"
        if h : value.utf8ByteSize ≤ 1024 * 1024 then log.set ⟨value, h⟩
        else throw (IO.userError "Trace: per-request log exceeds 1 MiB")

instance instExecutionError {ε : Type} [ToString ε] : Handler (Error.Error ε) Execution where
  handle request := fun ctx => do
    let _permission ← requireEffect ctx "Error"
    Handler.handle (m := IO) request

/-- Reject non-global IPv4, IPv6 special-use/tunnel and mapped ranges. DNS
    results are numeric strings from getaddrinfo, never notebook strings. -/
def publicAddress (address : String) : Bool :=
  match address.splitOn "." with
  | [a, b, c, d] => match a.toNat?, b.toNat?, c.toNat?, d.toNat? with
    | some a, some b, some c, some d =>
      a > 0 && a < 224 && b < 256 && c < 256 && d < 256 &&
      a != 10 && a != 127 && !(a == 100 && b ≥ 64 && b ≤ 127) &&
      !(a == 169 && b == 254) && !(a == 172 && b ≥ 16 && b ≤ 31) &&
      !(a == 192 && (b == 0 || b == 168 || (b == 88 && c == 99))) &&
      !(a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) &&
      !(a == 203 && b == 0 && c == 113)
    | _, _, _, _ => false
  | _ =>
    let hex (s : String) : Option Nat := do
      unless !s.isEmpty && s.length ≤ 4 && s.all Char.isHexDigit do none
      return s.toList.foldl (fun n c => n * 16 +
        (if c.isDigit then c.toNat - '0'.toNat else c.toLower.toNat - 'a'.toNat + 10)) 0
    match address.splitOn ":" with
    | first :: second :: _ => match hex first, hex second with
      | some first, second => first ≥ 0x2000 && first ≤ 0x3fff && first != 0x2002 &&
          !(first == 0x2001 && (second.getD 0 < 0x200 || second == some 0xdb8)) &&
          !(first == 0x3fff && second.getD 0 < 0x1000)
      | _, _ => false
    | _ => false

def validHTTPHost (labels : List String) : Bool :=
  !labels.isEmpty && labels.length ≤ 127 && labels.all (fun label =>
    !label.isEmpty && label.length ≤ 63 && !label.startsWith "-" && !label.endsWith "-" &&
    label.all (fun c => c.isAlphanum || c == '-'))

/-- The exact HTTP target, including canonical components and a DNS-validated
    pinned address. Path punctuation is encoded only after scope validation. -/
structure AuthorizedHTTP (ctx : ExecutionContext) (cap : HTTP.Capability) (method : Network.HTTP.Types.StdMethod) where
  url : HTTP.Url
  staticScope : cap.permits method url = true
  permission : EffectPermission ctx "HTTP"
  domain : ctx.domains.contains (".".intercalate url.host).toLower = true
  port : ((url.secure && url.port == 443) || (!url.secure && url.port == 80)) = true
  canonicalPath : Connector.Resource.valid url.path = true
  hostname : validHTTPHost url.host = true
  address : String
  global : publicAddress address = true

def AuthorizedHTTP.check (ctx : ExecutionContext) (cap : HTTP.Capability)
    (method : Network.HTTP.Types.StdMethod) (url : HTTP.Url) (scope : cap.permits method url = true) :
    IO (AuthorizedHTTP ctx cap method) := do
  let permission ← requireEffect ctx "HTTP"
  unless Connector.Resource.valid url.path && validHTTPHost url.host do
    throw (IO.userError "HTTP: noncanonical host or path components")
  if domain : ctx.domains.contains (".".intercalate url.host).toLower = true then
    if port : ((url.secure && url.port == 443) || (!url.secure && url.port == 80)) = true then
      let addresses ← Network.Socket.getAddrInfo (".".intercalate url.host) (toString url.port.toNat)
      unless !addresses.isEmpty && addresses.all (fun a => publicAddress a.host) do
        throw (IO.userError "HTTP: DNS resolves to a non-public address")
      let some first := addresses.head? | throw (IO.userError "HTTP: DNS has no addresses")
      let address := first.host
      if canonicalPath : Connector.Resource.valid url.path = true then
        if hostname : validHTTPHost url.host = true then
          if global : publicAddress address = true then return ⟨url, scope, permission, domain, port, canonicalPath, hostname, address, global⟩
  throw (IO.userError "organization permission denied: HTTP domain or port")

/-- Connect only to the validated numeric address, preserving the original
    Host and TLS verification/SNI. One request; redirects are not followed. -/
def sendAuthorizedHTTP {ctx : ExecutionContext} {cap : HTTP.Capability} {method : Network.HTTP.Types.StdMethod}
    (target : AuthorizedHTTP ctx cap method) (headers : Network.HTTP.Types.RequestHeaders)
    (query : Network.HTTP.Types.Query) (body : Option ByteArray) : IO Network.HTTP.Client.Response := do
  let encoded := { target.url with path := target.url.path.map Network.HTTP.Types.urlEncode }
  let request := HTTP.toClientRequest method encoded headers query body
  unless headers.all (fun (name, value) =>
      let name := (toString name).toLower
      !["host", "authorization", "proxy-authorization", "content-length", "transfer-encoding", "connection"].contains name &&
      !name.isEmpty && name.all (fun c => c.isAlphanum || c == '-') &&
      value.all (fun c => c.toNat ≥ 0x20 && c.toNat != 0x7f)) &&
      !request.path.contains '\r' && !request.path.contains '\n' && !request.path.contains ' ' do
    throw (IO.userError "HTTP: invalid headers or path")
  let (socket, _) ← Data.Streaming.Network.getSocketTCP target.address target.url.port
  try
    Network.Socket.setRecvTimeout socket 30000
    Network.Socket.setSendTimeout socket 30000
    if target.url.secure then
      let tls ← Network.TLS.connectSocket (← Network.TLS.createClientContext) socket.raw request.host
      try
        Network.HTTP.Client.performRequest
          { connRead := fun n => Network.TLS.read tls n.toUSize,
            connWrite := Network.TLS.write tls, connClose := pure (), connIsSecure := true } request
      finally Network.TLS.close tls
    else
      Network.HTTP.Client.performRequest
        { connRead := fun n => Network.Socket.Blocking.recv socket n 30000,
          connWrite := fun bytes => Network.Socket.Blocking.sendAll socket bytes 30000,
          connClose := pure (), connIsSecure := false } request
  finally let _ ← Network.Socket.close socket; pure ()

instance instExecutionHTTP {cap : HTTP.Capability} : Handler (HTTP.HTTP cap) Execution where
  handle
    | .request method _ url scope headers query body => fun ctx => do
      sendAuthorizedHTTP (← AuthorizedHTTP.check ctx cap method url scope) headers query body

/-- A relative path with evidence of both static rights and the current
    binding. The syscall adapter consumes this witness's components. -/
structure TemporaryPath (ctx : ExecutionContext) (cap : FileSystem.Capability) (op : FileSystem.Op) where
  path : FileSystem.Path
  staticScope : cap.permits op path = true
  permission : EffectPermission ctx "FileSystem"
  relative : (!path.isEmpty && Connector.Resource.valid path) = true
  binding : (Liaison.Wire.validAccountSegment ctx.org && Liaison.Wire.validAccountSegment ctx.user) = true

def TemporaryPath.check (ctx : ExecutionContext) (cap : FileSystem.Capability) (op : FileSystem.Op)
    (path : FileSystem.Path) (scope : cap.permits op path = true) : IO (TemporaryPath ctx cap op) := do
  let permission ← requireEffect ctx "FileSystem"
  if h : (!path.isEmpty && Connector.Resource.valid path) = true then
    if b : (Liaison.Wire.validAccountSegment ctx.org && Liaison.Wire.validAccountSegment ctx.user) = true then
      return ⟨path, scope, permission, h, b⟩
  throw (IO.userError "files: use a relative path under a valid organization/user binding")

def temporaryProgram : String := include_str "temporary.py"

def temporaryIO {ctx : ExecutionContext} {cap : FileSystem.Capability} {op : FileSystem.Op}
    (target : TemporaryPath ctx cap op) (bytes : ByteArray := ByteArray.empty) : IO ByteArray := do
  let operation := match op with | .read => "read" | .write => "write" | .delete => "delete"
  let root := (ctx.runtime.getObjValAs? String "LUN_TEMP_ROOT").toOption.getD "/tmp/typednotes"
  let input := Json.mkObj [("root", Json.str root), ("org", Json.str ctx.org), ("user", Json.str ctx.user),
    ("operation", Json.str operation), ("parts", toJson target.path), ("contents", Json.str (Data.Hex.encode bytes))]
  let r ← System.Process.run "python3" #["-I", "-c", temporaryProgram] 30000 (input := input.compress)
  unless r.ok do throw (IO.userError "scoped temporary-file operation refused")
  let data ← IO.ofExcept ((Json.parse r.stdout >>= fun j => j.getObjValAs? String "contents").mapError IO.userError)
  let some bytes := Data.Hex.decode data | throw (IO.userError "invalid temporary-file reply")
  return bytes

instance instExecutionFileSystem {cap : FileSystem.Capability} : Handler (FileSystem.FileSystem cap) Execution where
  handle
    | .readFile _ path scope => fun ctx => do temporaryIO (← TemporaryPath.check ctx cap .read path scope)
    | .writeFile _ path scope bytes => fun ctx => do let _ ← temporaryIO (← TemporaryPath.check ctx cap .write path scope) bytes; pure ()
    | .deleteFile _ path scope => fun ctx => do let _ ← temporaryIO (← TemporaryPath.check ctx cap .delete path scope); pure ()

/-- A bound grant is supplied by the authenticated app. The compiled function
    sees an effect capability, never its credential or warrant. -/
structure ConnectorGrant where
  provider : String
  connection : String
  account : String
  organization : Connector.Capability
  connectionPermissions : Connector.Capability
  cell : Connector.Capability
  warrantPermissions : Connector.Capability
  warrants : Array Json
  /-- Native ObjectStore effects bind one configured bucket/container. -/
  bucket : Option String := none

/-- Runtime metadata never inherits constructor defaults. Every ceiling has
    mandatory scopes and integral positive byte bounds, as in the broker. -/
def runtimeCapability := Connector.Capability.parse

instance : FromJson ConnectorGrant where
  fromJson? json := do
    let fields ← json.getObj?
    unless fields.toList.all (fun (key, _) => ["provider", "connection", "account", "organization", "connectionPermissions", "cell", "warrantPermissions", "warrants", "bucket"].contains key) do
      throw "unknown connector grant field"
    let provider ← json.getObjValAs? String "provider"
    let connection ← json.getObjValAs? String "connection"
    let account ← json.getObjValAs? String "account"
    let organization ← runtimeCapability (← json.getObjVal? "organization")
    let connectionPermissions ← runtimeCapability (← json.getObjVal? "connectionPermissions")
    let cell ← runtimeCapability (← json.getObjVal? "cell")
    -- The current app emits one cell ceiling and operation-specific tokens.
    -- Its envelope warrant ceiling is consequently bounded by that cell. The
    -- independent fourth ceiling still comes from the trusted run projection
    -- (or, for outbound Connector calls, is checked independently by liaison).
    let warrantPermissions ← match json.getObjVal? "warrantPermissions" with
      | .ok value => runtimeCapability value
      | .error _ => pure cell
    let warrants ← json.getObjValAs? (Array Json) "warrants"
    let bucket := (json.getObjValAs? String "bucket").toOption
    return { provider, connection, account, organization, connectionPermissions, cell, warrantPermissions, warrants, bucket }

/-- Local effects also require an expiring, bounded wire lease. A budget may
    not overflow the UInt64 encoding used by the signed caveat chain. -/
def completeWarrant (warrant : Liaison.Warrant) : Bool :=
  warrant.caveats.any (fun c => match c with | .expiresAt _ => true | _ => false) &&
  warrant.caveats.any (fun c => match c with | .budget _ => true | _ => false) &&
  warrant.caveats.all (fun c => match c with | .budget amount => amount < UInt64.size | _ => true)

structure CompleteWarrant (warrant : Liaison.Warrant) : Type where
  private mk ::
  validated : completeWarrant warrant = true

def requireWarrant (warrant : Liaison.Warrant) : IO (CompleteWarrant warrant) := do
  if h : completeWarrant warrant = true then return ⟨h⟩
  throw (IO.userError "warrant requires expiry and a bounded u64 budget")

instance instExecutionConnector {cap : Connector.Capability} : Handler (Connector.Connector cap) Execution where
  handle
    | .request operation resource staticPermission payload => fun ctx => do
      let _permission ← requireEffect ctx "Connector"
      let grants ← IO.ofExcept ((ctx.connectors.getObjValAs? (Array ConnectorGrant) ctx.functionName).mapError
        fun _ => IO.userError "invalid or missing fresh connector grants for this cell")
      let some grant := grants.find? (fun grant => grant.provider == cap.provider && grant.connection == cap.connection)
        | throw (IO.userError "this cell has no grant for that connector")
      let some credential := grant.warrants.find? (fun value => (value.getObjValAs? String "operation").toOption == some operation)
        | throw (IO.userError "no warrant permits this connector operation")
      let warrantJson ← IO.ofExcept ((credential.getObjVal? "warrant").mapError IO.userError)
      let warrantValue ← IO.ofExcept (Data.Json.Value.ofLeanJson warrantJson |>.mapError IO.userError)
      let warrant ← IO.ofExcept (Liaison.Wire.decodeWarrant warrantValue |>.mapError IO.userError)
      let _complete ← requireWarrant warrant
      let now := (← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000000
      let cost ← IO.ofExcept ((credential.getObjValAs? Nat "cost").mapError IO.userError)
      let request ← IO.ofExcept (Liaison.Wire.Request.ofWarrant warrant now.toUInt64 cost |>.mapError IO.userError)
      unless request.orgId.value == ctx.org && request.provider.value == cap.provider &&
          request.resource.value == cap.connection && request.action.value == operation &&
          warrant.permits request && Liaison.Wire.accountMatchesResource grant.account cap.connection do
        throw (IO.userError "connector warrant/account does not match the bound organization/user")
      let some narrowed := Connector.Capability.checkNarrows? grant.cell cap
        | throw (IO.userError "the runtime cell grant widens its compiled capability")
      let _ := narrowed.down
      let warrantCap := grant.warrantPermissions.onlyOperation operation
      let authority : Connector.Authority :=
        ⟨grant.organization, grant.connectionPermissions, grant.cell, warrantCap⟩
      let some authorized := Connector.AuthorizedRequest.check? authority operation resource payload
        | throw (IO.userError "connector authority denied the operation or resource")
      -- The static operation proof is also required by the effect constructor.
      let _ := staticPermission
      let body ← IO.ofExcept (Liaison.Wire.Body.connector warrant now.toUInt64 cost
        { account := grant.account, operation, resource := authorized.target.resource, payload := authorized.payload.compress } |>.mapError IO.userError)
      let some base := ctx.liaisonUrl | throw (IO.userError "the credential broker is not configured")
      let target ← Network.HTTP.Simple.parseUrl! (base ++ "/v0/egress")
      let outbound := { target with
        method := Network.HTTP.Types.Method.standard .POST
        headers := [(Network.HTTP.Types.hContentType, "application/json")]
        body := some body.encode.toUTF8 }
      let response ← Network.HTTP.Simple.httpBS outbound
      let reply ← IO.ofExcept (Liaison.Wire.decodeReply response.statusCode.statusCode ((String.fromUTF8? response.body).getD "") |>.mapError IO.userError)
      match reply with
      | .refused _ code => throw (IO.userError s!"credential broker denied the connector call: {code}")
      | .relayed result =>
        let some response := Connector.BoundedResponse.check? authority result.body
          | throw (IO.userError "connector response exceeds its size limit")
        let content := (String.fromUTF8? response.body).getD ""
        return Json.mkObj [("status", toJson result.status.toNat),
          ("body", (Json.parse content).toOption.getD (Json.str content))]

-- ── Bound compute database and graph vault ──────────────────────────────────

/-- Vault identity and target are private service configuration. -/
def vaultRequest (ctx : ExecutionContext) (method : Network.HTTP.Types.StdMethod)
    (path : String) (body : Option Json := none) : IO Network.HTTP.Client.Response := do
  let config := ctx.runtime
  let get (name : String) := (config.getObjValAs? String name).toOption
  let some host := get "SECRETS_HOST" | throw (IO.userError "lun vault identity is not configured")
  let secure := get "SECRETS_INSECURE" != some "1"
  let port := ((get "SECRETS_PORT").bind String.toNat?).getD (if secure then 443 else 80)
  unless port > 0 && port < 65536 do throw (IO.userError "invalid vault port")
  let send (method : Network.HTTP.Types.StdMethod) (path : String) (headers : Network.HTTP.Types.RequestHeaders)
      (body : Option Json) : IO Network.HTTP.Client.Response :=
    Network.HTTP.Simple.httpBS
      { method := .standard method, host, port := port.toUInt16, path, isSecure := secure,
        headers := (Network.HTTP.Types.hContentType, "application/json") :: headers,
        body := body.map (·.compress.toUTF8) }
  let token ← match get "SECRETS_USERNAME", get "SECRETS_PASSWORD", get "SECRETS_TOKEN" with
    | some username, some password, _ => do
      let response ← send .POST "/v1/auth/userpass/login" []
        (some (Json.mkObj [("username", Json.str username), ("password", Json.str password)]))
      unless response.isSuccess do throw (IO.userError "lun vault login was refused")
      IO.ofExcept ((Json.parse ((String.fromUTF8? response.body).getD "") >>= fun j =>
        j.getObjVal? "auth" >>= fun j => j.getObjValAs? String "client_token").mapError fun _ => IO.userError "invalid vault login response")
    | none, _, some token => pure token
    | _, _, _ => throw (IO.userError "lun vault identity is not configured")
  send method path [(Network.HTTP.Types.hAuthorization, s!"Bearer {token}")] body

def vaultJson (response : Network.HTTP.Client.Response) : IO Json := do
  unless response.isSuccess do throw (IO.userError "bound vault operation was refused")
  let text := (String.fromUTF8? response.body).getD ""
  let parsed : Except String Json := do
    let value ← Data.Json.Decode.decode text
    unless Liaison.Wire.uniqueKeys value do throw "ambiguous vault JSON"
    Json.parse text
  IO.ofExcept (parsed.mapError fun _ => IO.userError "invalid vault response")

/-- Validated logical-to-physical routes are read only from protected authority
    documents. They preserve merged-note secret values without exposing keys. -/
structure SecretRoute where
  private mk ::
  logical : Connector.Resource
  vaultGraph : String
  physical : Connector.Resource
  namespaceBound : Liaison.Wire.validAccountSegment vaultGraph = true
  logicalBound : Connector.Resource.valid logical = true
  physicalBound : Connector.Resource.valid physical = true

def secretRoute (j : Json) : Except String SecretRoute := do
  let fields ← j.getObj?
  unless fields.toList.all (fun (k,_) => ["logical","namespace","physical"].contains k) do throw "unknown secret route field"
  let logical ← j.getObjValAs? (List String) "logical"
  let vaultGraph ← j.getObjValAs? String "namespace"
  let physical ← j.getObjValAs? (List String) "physical"
  unless !logical.isEmpty && !physical.isEmpty do throw "secret routes cannot alias a directory"
  if hn : Liaison.Wire.validAccountSegment vaultGraph = true then
    if hl : Connector.Resource.valid logical = true then
      if hp : Connector.Resource.valid physical = true then return ⟨logical,vaultGraph,physical,hn,hl,hp⟩
  throw "invalid secret route scope"

/-- Live non-cell ceilings, resolved from namespaces only the trusted minting
    service may write. The cell is kept separately to retain its static proof. -/
structure NativeCeilings (grant : ConnectorGrant) (operation : String) where
  private mk ::
  organization : Connector.Capability
  connection : Connector.Capability
  warrant : Connector.Capability
  cell : Connector.Capability
  organizationBound : grant.organization.Narrows organization
  connectionBound : grant.connectionPermissions.Narrows connection
  cellBound : grant.cell.Narrows cell
  warrantBound : (grant.warrantPermissions.onlyOperation operation).Narrows warrant
  routes : Array SecretRoute

def nativeAuthority (ctx : ExecutionContext) (cap : Connector.Capability) (grant : ConnectorGrant)
    (warrant : Liaison.Warrant) (request : Liaison.Request) : IO (NativeCeilings grant request.action.value) := do
  unless [ctx.org, ctx.user, cap.provider, cap.connection, request.runId.value, warrant.id.value].all Liaison.Wire.validAccountSegment do
    throw (IO.userError "invalid native authority identity")
  let document (path : String) : IO Json := do
    let json ← vaultJson (← vaultRequest ctx .GET ("/v1/secret/data/" ++ path))
    IO.ofExcept ((json.getObjVal? "data").mapError fun _ => IO.userError "invalid native authority document")
  let ceiling (path : String) : IO Connector.Capability := do
    let json ← document path
    let fields ← IO.ofExcept ((json.getObj?).mapError IO.userError)
    unless fields.toList.all (fun (key, _) => ["scopes", "maxRequestBytes", "maxResponseBytes"].contains key) do
      throw (IO.userError "unknown native policy field")
    IO.ofExcept ((runtimeCapability ((json.setObjVal! "provider" (Json.str cap.provider)).setObjVal! "connection" (Json.str cap.connection))).mapError IO.userError)
  let organization ← ceiling s!"connector-policy/{ctx.org}/{cap.provider}/{cap.connection}"
  let owner ← match grant.account.splitOn "/" with
    | [owner, connection] =>
      if Liaison.Wire.validAccountSegment owner && connection == cap.connection then pure owner
      else throw (IO.userError "native account leaves its named connection binding")
    | _ => throw (IO.userError "invalid native account")
  let connection ← ceiling s!"thirdparty/{cap.provider}/{owner}/{cap.connection}/permissions"
  let projection ← document s!"connector-authority/{ctx.org}/{request.runId.value}/{warrant.id.value}"
  let parsed : Except String (Connector.Capability × Connector.Capability) := do
    let fields ← projection.getObj?
    unless fields.toList.all (fun (key, _) => ["account", "cell", "warrant", "routes"].contains key) do throw "unknown native projection field"
    unless (← projection.getObjValAs? String "account") == grant.account do throw "native authority account mismatch"
    return (← runtimeCapability (← projection.getObjVal? "cell"), ← runtimeCapability (← projection.getObjVal? "warrant"))
  let (cell, warrant) ← IO.ofExcept (parsed.mapError IO.userError)
  let routes ← IO.ofExcept ((do
    match projection.getObjVal? "routes" with
    | .error _ => return #[]
    | .ok value =>
      unless cap.provider == "vault" do throw "secret routing is unavailable to this provider"
      let values : Array Json ← fromJson? value
      unless values.size ≤ 1000 do throw "too many project secret routes"
      values.mapM secretRoute).mapError IO.userError)
  let requestedWarrant := grant.warrantPermissions.onlyOperation request.action.value
  let some orgBound := grant.organization.checkNarrows? organization
    | throw (IO.userError "native request ceilings exceed the live stored authority")
  let some connectionBound := grant.connectionPermissions.checkNarrows? connection
    | throw (IO.userError "native request ceilings exceed the live stored authority")
  let some cellBound := grant.cell.checkNarrows? cell
    | throw (IO.userError "native request ceilings exceed the live stored authority")
  let some warrantBound := requestedWarrant.checkNarrows? warrant
    | throw (IO.userError "native request ceilings exceed the live stored authority")
  return ⟨organization, connection, warrant, cell, orgBound.down, connectionBound.down, cellBound.down, warrantBound.down,routes⟩

/-- Local native operations consume a four-ceiling resource/payload witness and
    evidence for every warrant caveat. Authenticity is the authenticated app's
    trust boundary here; outbound connectors additionally verify at liaison. -/
structure NativeOperation (ctx : ExecutionContext) (cap : Connector.Capability) (op : String) (resource : Connector.Resource) where
  private mk ::
  grant : ConnectorGrant
  authority : Connector.Authority
  exactAuthority : authority = ⟨grant.organization, grant.connectionPermissions, grant.cell, grant.warrantPermissions.onlyOperation op⟩
  live : NativeCeilings grant op
  authorized : Connector.AuthorizedRequest authority op
  exactResource : authorized.target.resource = resource
  staticBound : authority.cell.Narrows cap
  warrant : Liaison.Warrant
  complete : CompleteWarrant warrant
  request : Liaison.Request
  caveats : warrant.permits request
  organization : request.orgId.value = ctx.org
  operation : request.action.value = op
  provider : request.provider.value = cap.provider
  connection : request.resource.value = cap.connection

theorem NativeOperation.organization_permits (call : NativeOperation ctx cap op resource) :
    call.authority.organization.permits op resource = true := by
  simpa only [call.exactResource] using call.authorized.target.organization_permits

theorem NativeOperation.connection_permits (call : NativeOperation ctx cap op resource) :
    call.authority.connection.permits op resource = true := by
  simpa only [call.exactResource] using call.authorized.target.connection_permits

theorem NativeOperation.cell_permits (call : NativeOperation ctx cap op resource) :
    call.authority.cell.permits op resource = true := by
  simpa only [call.exactResource] using call.authorized.target.cell_permits

theorem NativeOperation.warrant_permits (call : NativeOperation ctx cap op resource) :
    call.authority.warrant.permits op resource = true := by
  simpa only [call.exactResource] using call.authorized.target.warrant_permits

theorem NativeOperation.static_permits (call : NativeOperation ctx cap op resource) :
    cap.permits op resource = true := call.staticBound.2.2.2.2 op resource call.cell_permits

/-- Execution retains the attenuation witnesses against the freshly fetched
    documents, rather than merely checking and discarding them. -/
theorem NativeOperation.live_organization_permits (call : NativeOperation ctx cap op resource) :
    call.live.organization.permits op resource = true := by
  apply call.live.organizationBound.2.2.2.2 op resource
  simpa only [call.exactAuthority] using call.organization_permits

theorem NativeOperation.live_connection_permits (call : NativeOperation ctx cap op resource) :
    call.live.connection.permits op resource = true := by
  apply call.live.connectionBound.2.2.2.2 op resource
  simpa only [call.exactAuthority] using call.connection_permits

theorem NativeOperation.live_cell_permits (call : NativeOperation ctx cap op resource) :
    call.live.cell.permits op resource = true := by
  apply call.live.cellBound.2.2.2.2 op resource
  simpa only [call.exactAuthority] using call.cell_permits

theorem NativeOperation.live_warrant_permits (call : NativeOperation ctx cap op resource) :
    call.live.warrant.permits op resource = true := by
  apply call.live.warrantBound.2.2.2.2 op resource
  simpa only [call.exactAuthority] using call.warrant_permits

theorem NativeOperation.live_request_bounded (call : NativeOperation ctx cap op resource) :
    call.authorized.payload.compress.toUTF8.size ≤ call.live.organization.maxRequestBytes ∧
    call.authorized.payload.compress.toUTF8.size ≤ call.live.connection.maxRequestBytes ∧
    call.authorized.payload.compress.toUTF8.size ≤ call.live.cell.maxRequestBytes ∧
    call.authorized.payload.compress.toUTF8.size ≤ call.live.warrant.maxRequestBytes := by
  have organization := call.authorized.organization_bounded
  have connection := call.authorized.connection_bounded
  have cell := call.authorized.cell_bounded
  have warrant := call.authorized.warrant_bounded
  simp only [call.exactAuthority] at organization connection cell warrant
  exact ⟨Nat.le_trans organization call.live.organizationBound.2.2.1,
    Nat.le_trans connection call.live.connectionBound.2.2.1,
    Nat.le_trans cell call.live.cellBound.2.2.1,
    Nat.le_trans warrant call.live.warrantBound.2.2.1⟩

def NativeOperation.check (ctx : ExecutionContext) (cap : Connector.Capability) (op : String)
    (resource : Connector.Resource) (payload : Json := Json.mkObj []) : IO (NativeOperation ctx cap op resource) := do
  let grants ← IO.ofExcept ((ctx.connectors.getObjValAs? (Array ConnectorGrant) ctx.functionName).mapError fun _ => IO.userError "no native operation grant")
  let some grant := grants.find? (fun g => g.provider == cap.provider && g.connection == cap.connection)
    | throw (IO.userError "no native connection grant")
  unless Liaison.Wire.accountMatchesResource grant.account cap.connection do
    throw (IO.userError "native account leaves its named connection binding")
  if ["postgres", "vault"].contains cap.provider then
    unless grant.account == s!"{ctx.user}/{cap.connection}" do throw (IO.userError "native account leaves the user binding")
  let some narrowed := grant.cell.checkNarrows? cap | throw (IO.userError "native cell grant widens its compiled capability")
  let some token := grant.warrants.find? (fun j => (j.getObjValAs? String "operation").toOption == some op)
    | throw (IO.userError "no fresh native operation warrant")
  let warrant ← IO.ofExcept ((token.getObjVal? "warrant" >>= Data.Json.Value.ofLeanJson >>= Liaison.Wire.decodeWarrant).mapError fun _ => IO.userError "malformed native warrant")
  let complete ← requireWarrant warrant
  let now := (← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000000
  let cost ← IO.ofExcept ((token.getObjValAs? Nat "cost").mapError fun _ => IO.userError "native warrant requires an explicit cost")
  let request ← IO.ofExcept ((Liaison.Wire.Request.ofWarrant warrant now.toUInt64 cost).mapError IO.userError)
  if organization : request.orgId.value = ctx.org then
    if operation : request.action.value = op then
      if provider : request.provider.value = cap.provider then
        if connection : request.resource.value = cap.connection then
          if caveats : warrant.permits request then
            -- Local effects independently fetch the live organization and
            -- connection ceilings and the trusted minting projection. Request
            -- metadata cannot replace any of these server-owned documents.
            let ceilings ← nativeAuthority ctx cap grant warrant request
            let ceilings : NativeCeilings grant op := operation ▸ ceilings
            -- Both persisted live ceilings and the current request's narrower
            -- ceilings remain load-bearing. Never substitute the broader live
            -- document for an attenuated request grant.
            let authority : Connector.Authority := ⟨grant.organization, grant.connectionPermissions, grant.cell, grant.warrantPermissions.onlyOperation op⟩
            let some authorized := Connector.AuthorizedRequest.check? authority op resource payload
              | throw (IO.userError "native operation exceeds a capability ceiling")
            if same : authorized.target.resource = resource then
              return ⟨grant, authority, rfl, ceilings, authorized, same, narrowed.down, warrant, complete, request, caveats, organization, operation, provider, connection⟩
  throw (IO.userError "native warrant caveats or binding refused the operation")

/-- The broker verifies the signed warrant before using its credential. This
    transport consumes the exact resource/payload witness, and no URL override. -/
def relayNative {ctx : ExecutionContext} {cap : Connector.Capability} {op : String} {resource : Connector.Resource}
    (call : NativeOperation ctx cap op resource) : IO Liaison.Wire.Response := do
  let body ← IO.ofExcept ((Liaison.Wire.Body.connector call.warrant call.request.now call.request.cost
    { account := call.grant.account, operation := op, resource := call.authorized.target.resource,
      payload := call.authorized.payload.compress }).mapError IO.userError)
  let some base := ctx.liaisonUrl | throw (IO.userError "the credential broker is not configured")
  let request ← Network.HTTP.Simple.parseUrl! (base ++ "/v0/egress")
  let outbound := { request with
    method := Network.HTTP.Types.Method.standard .POST
    headers := [(Network.HTTP.Types.hContentType, "application/json")]
    body := some body.encode.toUTF8 }
  let response ← Network.HTTP.Simple.httpBS outbound
  let reply ← IO.ofExcept ((Liaison.Wire.decodeReply response.statusCode.statusCode
    ((String.fromUTF8? response.body).getD "")).mapError IO.userError)
  match reply with
  | .refused _ code => throw (IO.userError s!"credential broker denied the native call: {code}")
  | .relayed result =>
    let some response := Connector.BoundedResponse.check? call.authority result.body
      | throw (IO.userError "native response exceeds its size ceiling")
    return { result with body := response.body }

def objectOperation : ObjectStore.Op → String
  | .get => "objects.read" | .put => "objects.write" | .delete => "objects.delete" | .list => "objects.list"

def objectCapability (cap : ObjectStore.Capability) (grant : ConnectorGrant) (bucket : String) : Connector.Capability :=
  { provider := grant.provider, connection := grant.connection,
    scopes := cap.scopes.flatMap fun scope =>
      if scope.bucket != bucket then [] else
        ([.get, .put, .delete, .list].filter fun op =>
          cap.allows op && (scope.ops.isEmpty || scope.ops.contains op)).map fun op =>
            { operation := objectOperation op, root := scope.keyPrefix } }

def boundObjectCall (ctx : ExecutionContext) (cap : ObjectStore.Capability)
    (op : ObjectStore.Op) (bucket : String) (key : ObjectStore.Key)
    (_scope : cap.permits op bucket key = true) (payload : Json := Json.mkObj []) : IO Liaison.Wire.Response := do
  let _permission ← requireEffect ctx "ObjectStore"
  let grants ← IO.ofExcept ((ctx.connectors.getObjValAs? (Array ConnectorGrant) ctx.functionName).mapError fun _ => IO.userError "no object-store grant")
  let matching := grants.filter fun grant => ["s3", "azure"].contains grant.provider && grant.bucket == some bucket
  unless matching.size == 1 do throw (IO.userError "ObjectStore requires exactly one connection bound to this bucket")
  let some grant := matching[0]? | throw (IO.userError "no bound object connection")
  let call ← NativeOperation.check ctx (objectCapability cap grant bucket) (objectOperation op) key payload
  relayNative call

def objectSuccess (reply : Liaison.Wire.Response) : IO Unit :=
  unless reply.status.toNat ≥ 200 && reply.status.toNat < 300 do
    throw (IO.userError s!"object operation was refused: HTTP {reply.status.toNat}")

def objectMetadata (key : ObjectStore.Key) (reply : Liaison.Wire.Response) : Cloud.ObjectMeta :=
  { key := ObjectStore.Key.render key, size := reply.body.size,
    etag := reply.header? "etag", contentType := reply.header? "content-type", lastModified := reply.header? "last-modified" }

instance instExecutionObjectStore {cap : ObjectStore.Capability} : Handler (ObjectStore.ObjectStore cap) Execution where
  handle
    | .get _ bucket key scope => fun ctx => do
      let reply ← boundObjectCall ctx cap .get bucket key scope
      objectSuccess reply
      return .ok reply.body
    | .head _ bucket key scope => fun ctx => do
      let reply ← boundObjectCall ctx cap .get bucket key scope
      if reply.status == 404 then return .ok none
      objectSuccess reply
      return .ok (some (objectMetadata key reply))
    | .put _ bucket key scope body options => fun ctx => do
      let some contents := String.fromUTF8? body | throw (IO.userError "the broker object adapter requires UTF-8 writes")
      unless options.cacheControl.isNone && options.metadata.isEmpty && options.contentType.isNone do
        throw (IO.userError "the broker object adapter does not support write metadata")
      let reply ← boundObjectCall ctx cap .put bucket key scope (Json.mkObj [("contents", Json.str contents)])
      objectSuccess reply
      return .ok { (objectMetadata key reply) with size := body.size }
    | .delete _ bucket key scope => fun ctx => do
      let reply ← boundObjectCall ctx cap .delete bucket key scope
      if reply.status != 404 then objectSuccess reply
      return .ok ()
    | .list _ bucket key scope cursor => fun ctx => do
      unless cursor.isNone do throw (IO.userError "the broker object adapter does not yet support pagination cursors")
      let reply ← boundObjectCall ctx cap .list bucket key scope
      objectSuccess reply
      let root ← IO.ofExcept ((Text.XML.parse ((String.fromUTF8? reply.body).getD "")).mapError fun _ => IO.userError "invalid object listing")
      let elements := root.named "Contents" ++ ((root.named "Blobs").flatMap (·.named "Blob"))
      let items : List Cloud.ObjectMeta ← elements.mapM fun element => do
        let some name := (element.childText "Key").orElse fun _ => element.childText "Name"
          | throw (IO.userError "object listing has no key")
        let parts := name.splitOn "/"
        unless key.isPrefixOf parts && cap.permits .list bucket parts do
          throw (IO.userError "object listing leaves its authorized prefix")
        return { key := name, size := ((element.childText "Size").bind String.toNat?).getD 0 }
      let next := ((root.childText "NextContinuationToken").orElse fun _ => root.childText "NextMarker").filter (!·.isEmpty) |>.map Cloud.Cursor.mk
      return .ok { items, next }

def postgresOperation : PostgreSQL.Op → String
  | .select => "rows.select" | .insert => "rows.insert" | .update => "rows.update" | .delete => "rows.delete"

def postgresCapability (ctx : ExecutionContext) (cap : PostgreSQL.Capability) : Connector.Capability :=
  { provider := "postgres", connection := "compute", scopes :=
    ([.select, .insert, .update, .delete].filter (cap.allows ·)).flatMap fun op =>
        if cap.tables.isEmpty then [{ operation := postgresOperation op, root := [ctx.schema] }]
        else cap.tables.map fun table => { operation := postgresOperation op, root := [table.schema, table.name], descendants := false } }

/-- Credential target resolved exclusively at compute/{org}/{user}. The
    constructor is private; notebook code receives neither it nor its password. -/
structure ComputeCredential (ctx : ExecutionContext) where
  private mk ::
  host : String
  port : UInt16
  database : String
  schema : String
  private password : String
  boundSchema : schema = ctx.schema

def ComputeCredential.resolve (ctx : ExecutionContext) : IO (ComputeCredential ctx) := do
  unless Liaison.Wire.validAccountSegment ctx.org && Liaison.Wire.validAccountSegment ctx.user &&
      !ctx.schema.isEmpty && ctx.schema.length ≤ 63 &&
      ctx.schema.all (fun c => c.isLower || c.isDigit || c == '_') do
    throw (IO.userError "invalid compute organization/user/schema binding")
  let root ← vaultJson (← vaultRequest ctx .GET s!"/v1/secret/data/compute/{ctx.org}/{ctx.user}")
  let read : Except String (String × String × String × String) := do
    let value ← root.getObjVal? "data"
    unless (← value.getObjValAs? String "kind") == "postgres" do throw "invalid compute credential kind"
    return (← value.getObjValAs? String "base_url", ← value.getObjValAs? String "database",
      ← value.getObjValAs? String "schema", ← value.getObjValAs? String "token")
  let (base, database, schema, password) ← IO.ofExcept (read.mapError fun _ => IO.userError "invalid compute credential")
  let (host, port) ← match base.splitOn ":" with
    | [host, port] => do
      let some port := port.toNat? | throw (IO.userError "invalid compute port")
      unless port > 0 && port < 65536 do throw (IO.userError "invalid compute port")
      pure (host, port.toUInt16)
    | _ => throw (IO.userError "invalid compute target")
  -- libpq component rendering is unquoted. Admit only single safe tokens.
  unless !host.isEmpty && host.all (fun c => c.isAlphanum || c == '-' || c == '.') &&
      !database.isEmpty && database.all (fun c => c.isAlphanum || c == '_' || c == '-') &&
      !password.isEmpty && password.all (fun c => c.isAlphanum || c == '_' || c == '-') do
    throw (IO.userError "invalid compute credential fields")
  if bound : schema = ctx.schema then return ⟨host, port, database, schema, password, bound⟩
  throw (IO.userError "compute credential does not match the bound schema")

/-- A schema-confined, statically permitted query. Dispatch consumes this same
    AST, so checked identifiers and the rendered SQL cannot disagree. -/
structure AuthorizedQuery (ctx : ExecutionContext) (cap : PostgreSQL.Capability) where
  query : PostgreSQL.Query
  staticScope : cap.permits query = true
  schema : query.table.schema = ctx.schema
  tableBytes : query.table.name.toUTF8.size ≤ 63
  permission : EffectPermission ctx "PostgreSQL"
  native : NativeOperation ctx (postgresCapability ctx cap) (postgresOperation query.op) [query.table.schema, query.table.name]

theorem AuthorizedQuery.organization_permits {ctx : ExecutionContext} {cap : PostgreSQL.Capability}
    (q : AuthorizedQuery ctx cap) :
    q.native.authority.organization.permits (postgresOperation q.query.op) [q.query.table.schema, q.query.table.name] = true := by
  have h := q.native.authorized.target.organization_permits
  simpa only [q.native.exactResource] using h

theorem AuthorizedQuery.schema_confined {ctx : ExecutionContext} {cap : PostgreSQL.Capability}
    (q : AuthorizedQuery ctx cap) : q.query.table.schema = ctx.schema := q.schema

def AuthorizedQuery.check (ctx : ExecutionContext) (cap : PostgreSQL.Capability)
    (query : PostgreSQL.Query) (scope : cap.permits query = true) : IO (AuthorizedQuery ctx cap) := do
  let permission ← requireEffect ctx "PostgreSQL"
  if schema : query.table.schema = ctx.schema then
    if tableBytes : query.table.name.toUTF8.size ≤ 63 then
      let (sql, parameters) := query.render
      let payload := Json.mkObj [("sql", Json.str sql), ("parameters", toJson parameters)]
      let native ← NativeOperation.check ctx (postgresCapability ctx cap) (postgresOperation query.op) [query.table.schema, query.table.name] payload
      return ⟨query, scope, schema, tableBytes, permission, native⟩
    throw (IO.userError "PostgreSQL: table identifier would be truncated by the server")
  throw (IO.userError "PostgreSQL: query leaves the bound user's schema")

/-- A privately constructed target whose host/database/role are the resolved
    service credential's, with kernel evidence of the compiled static ceiling. -/
structure BoundCompute (ctx : ExecutionContext) (cap : PostgreSQL.Capability) where
  private mk ::
  credential : ComputeCredential ctx
  host : cap.host = credential.host
  port : cap.port = credential.port
  database : cap.database = credential.database
  role : cap.user = credential.schema

theorem BoundCompute.role_confined {ctx : ExecutionContext} {cap : PostgreSQL.Capability}
    (target : BoundCompute ctx cap) : cap.user = ctx.schema :=
  target.role.trans target.credential.boundSchema

def BoundCompute.resolve (ctx : ExecutionContext) (cap : PostgreSQL.Capability) : IO (BoundCompute ctx cap) := do
  let credential ← ComputeCredential.resolve ctx
  if host : cap.host = credential.host then
    if port : cap.port = credential.port then
      if database : cap.database = credential.database then
        if role : cap.user = credential.schema then return ⟨credential, host, port, database, role⟩
  throw (IO.userError "PostgreSQL: compiled target does not match the bound compute credential")

def executeQuery {ctx : ExecutionContext} {cap : PostgreSQL.Capability}
    (authorized : AuthorizedQuery ctx cap) : IO Database.PostgreSQL.LibPQ.PgResult := do
  let target ← BoundCompute.resolve ctx cap
  let credential := target.credential
  let settings := Database.SQL.Connection.Settings.components credential.host credential.port.toNat
    credential.schema credential.password credential.database
  let result ← Database.SQL.Connection.withConnection settings fun connection => do
    let (sql, params) := authorized.query.render
    Database.SQL.Session.Session.run (Database.SQL.Session.Session.query sql params) connection
  match result with
  | .ok (.ok rows) => return rows
  | _ => throw (IO.userError "bound PostgreSQL query was refused")

/-- The returned rows themselves carry the response-ceiling evidence. -/
structure BoundedRows (authority : Connector.Authority) where
  private mk ::
  rows : PostgreSQL.ResultSet
  bounded : (Json.mkObj [("columns", toJson rows.columns), ("rows", toJson rows.rows)]).compress.toUTF8.size ≤ authority.maxResponseBytes

def BoundedRows.check? (authority : Connector.Authority) (rows : PostgreSQL.ResultSet) : Option (BoundedRows authority) :=
  if h : (Json.mkObj [("columns", toJson rows.columns), ("rows", toJson rows.rows)]).compress.toUTF8.size ≤ authority.maxResponseBytes then
    some ⟨rows, h⟩ else none

instance instExecutionPostgreSQL {cap : PostgreSQL.Capability} : Handler (PostgreSQL.PostgreSQL cap) Execution where
  handle
    | .query _ query _ scope => fun ctx => do
      -- App bindings carry org/user/graph, not an independently chosen schema.
      -- The capability names its intended role; BoundCompute subsequently
      -- proves it equals the credential fetched ONLY at compute/{org}/{user}.
      unless ctx.schema.isEmpty || ctx.schema == cap.user do
        throw (IO.userError "PostgreSQL: declared schema leaves the compute role binding")
      let ctx := { ctx with schema := cap.user }
      let authorized ← AuthorizedQuery.check ctx cap query scope
      let rows ← PostgreSQL.ResultSet.ofPgResult (← executeQuery authorized)
      let some bounded := BoundedRows.check? authorized.native.authority rows
        | throw (IO.userError "PostgreSQL response exceeds its size ceiling")
      return bounded.rows
    | .command query _ _ scope => fun ctx => do
      unless ctx.schema.isEmpty || ctx.schema == cap.user do
        throw (IO.userError "PostgreSQL: declared schema leaves the compute role binding")
      let ctx := { ctx with schema := cap.user }
      let authorized ← AuthorizedQuery.check ctx cap query scope
      let result ← executeQuery authorized
      let affected := (← Database.PostgreSQL.LibPQ.cmdTuples result).toNat?.getD 0
      let some bounded := Connector.BoundedResponse.check? authorized.native.authority (toJson affected).compress.toUTF8
        | throw (IO.userError "PostgreSQL response exceeds its size ceiling")
      let _ := bounded.bounded
      return affected

def secretOperation : SecretStore.Op → String
  | .describe => "secrets.describe" | .getValue => "secrets.read" | .put => "secrets.write" | .list => "secrets.list"

def graphSecretCapability (ctx : ExecutionContext) (cap : SecretStore.Capability) : Connector.Capability :=
  { provider := "vault", connection := ctx.graph, scopes := cap.scopes.flatMap fun scope =>
      ([.describe, .getValue, .put, .list].filter fun op =>
        cap.allows op && (scope.ops.isEmpty || scope.ops.contains op)).map fun op =>
          { operation := secretOperation op, root := scope.namePrefix } }

/-- A logical project secret name cannot select compute credentials or another
    organization. Physical routes come exclusively from protected projections. -/
structure GraphSecret (ctx : ExecutionContext) (cap : SecretStore.Capability) (op : SecretStore.Op) where
  private mk ::
  name : SecretStore.Name
  staticScope : cap.permits op name = true
  relative : Connector.Resource.valid name = true
  graphBound : Liaison.Wire.validAccountSegment ctx.graph = true
  permission : EffectPermission ctx "SecretStore"
  native : NativeOperation ctx (graphSecretCapability ctx cap) (secretOperation op) name
  routedGraph : String
  routedName : Connector.Resource
  routeBound : Liaison.Wire.validAccountSegment routedGraph = true
  exactRoute : (routedGraph,routedName) = ((native.live.routes.find? (·.logical == name)).map (fun r => (r.vaultGraph,r.physical))).getD (ctx.graph,name)

def GraphSecret.check (ctx : ExecutionContext) (cap : SecretStore.Capability) (op : SecretStore.Op)
    (name : SecretStore.Name) (scope : cap.permits op name = true) (payload : Json := Json.mkObj []) : IO (GraphSecret ctx cap op) := do
  let permission ← requireEffect ctx "SecretStore"
  if relative : Connector.Resource.valid name = true then
    if bound : Liaison.Wire.validAccountSegment ctx.graph = true then
      let native ← NativeOperation.check ctx (graphSecretCapability ctx cap) (secretOperation op) name payload
      let routing := ((native.live.routes.find? (·.logical == name)).map (fun r => (r.vaultGraph,r.physical))).getD (ctx.graph,name)
      if hr : Liaison.Wire.validAccountSegment routing.1 = true then
        return ⟨name, scope, relative, bound, permission, native,routing.1,routing.2,hr,rfl⟩
  throw (IO.userError "invalid graph-secret binding or name")

def GraphSecret.path {ctx : ExecutionContext} {cap : SecretStore.Capability} {op : SecretStore.Op}
    (name : GraphSecret ctx cap op) (kind : String := "data") : String :=
  s!"/v1/secret/{kind}/graph/{ctx.org}/{name.routedGraph}/" ++
    "/".intercalate (name.routedName.map Network.HTTP.Types.urlEncode)

def boundedVaultJson (authority : Connector.Authority) (response : Network.HTTP.Client.Response) : IO Json := do
  let some bounded := Connector.BoundedResponse.check? authority response.body
    | throw (IO.userError "graph-secret response exceeds its size ceiling")
  vaultJson { response with body := bounded.body }

instance instExecutionSecretStore {cap : SecretStore.Capability} : Handler (SecretStore.SecretStore cap) Execution where
  handle
    | .getValue _ name scope => fun ctx => do
      let target ← GraphSecret.check ctx cap .getValue name scope
       let response ← vaultRequest ctx .GET target.path
       let root ← boundedVaultJson target.native.authority response
      let value ← IO.ofExcept ((root.getObjVal? "data" >>= fun j => j.getObjValAs? String "value").mapError fun _ => IO.userError "invalid graph secret")
      return .ok (Cloud.Secret.Value.ofString value)
    | .put _ name scope value => fun ctx => do
      let some value := value.exposeString? | throw (IO.userError "graph vault requires UTF-8 values")
      let target ← GraphSecret.check ctx cap .put name scope (Json.mkObj [("value", Json.str value)])
      let response ← vaultRequest ctx .POST target.path (some target.native.authorized.payload)
      unless response.isSuccess do throw (IO.userError "graph-secret write was refused")
      return .ok { name := SecretStore.Name.render target.name }
     | .describe _ name scope => fun ctx => do
       let target ← GraphSecret.check ctx cap .describe name scope
       let response ← vaultRequest ctx .GET target.path
       if response.statusCode.statusCode == 404 then return .ok none
       let _ ← boundedVaultJson target.native.authority response
       return .ok (some { name := SecretStore.Name.render target.name })
     | .getVersion _ _ _ _ => fun ctx => do
       let _ ← requireEffect ctx "SecretStore"
       pure (.error (Cloud.Error.protocol "vault historical reads are not supported by this backend"))
    | .list _ prefix' scope cursor => fun ctx => do
      unless cursor.isNone do throw (IO.userError "the graph vault does not support pagination cursors")
       let target ← GraphSecret.check ctx cap .list prefix' scope
       if !target.native.live.routes.isEmpty then
         let items := target.native.live.routes.toList.filterMap fun route =>
           if prefix'.isPrefixOf route.logical && cap.permits .list route.logical then some ({name := SecretStore.Name.render route.logical} : Cloud.Secret.Metadata) else none
         return .ok {items,next := none}
       let response ← vaultRequest ctx .GET (target.path "metadata" ++ (if prefix'.isEmpty then "" else "/"))
       let root ← boundedVaultJson target.native.authority response
      let keys ← IO.ofExcept ((root.getObjValAs? (List String) "keys").mapError fun _ => IO.userError "invalid graph-secret listing")
      let boundPrefix := ["graph", ctx.org, ctx.graph]
      let items : List Cloud.Secret.Metadata ← keys.mapM fun key => do
        let parts := key.splitOn "/"
        let relative := parts.drop 3
        unless boundPrefix.isPrefixOf parts && target.name.isPrefixOf relative && cap.permits .list relative do
          throw (IO.userError "graph-secret listing leaves its scope")
        return { name := SecretStore.Name.render relative }
      return .ok { items, next := none }

-- ── Which Lean functions lun serves ─────────────────────────────────────────

/-- A type a served function can have, and how to call such a function on JSON
    arguments. -/
class FunctionType (σ : Type 1) where
  /-- The argument types that take an input (`Unit` arguments do not). -/
  Args : List Type
  /-- The value the function produces. -/
  Out : Type
  /-- `Args.length`. -/
  arity : Nat
  /-- Call on exactly `arity` JSON arguments; throws on a decoding error, a
      wrong argument count, or the effect's own error. -/
  call : σ → List Json → Execution Json

/-- A `Unit` argument takes no input. -/
instance (priority := high) instFunctionTypeUnit {σ : Type 1} [FunctionType σ] : FunctionType (Unit → σ) where
  Args := FunctionType.Args σ
  Out := FunctionType.Out σ
  arity := FunctionType.arity σ
  call f js := FunctionType.call (f ()) js

/-- A JSON-decodable argument takes one input. -/
instance instFunctionTypeArrow {α : Type} {σ : Type 1} [FromJson α] [FunctionType σ] : FunctionType (α → σ) where
  Args := α :: FunctionType.Args σ
  Out := FunctionType.Out σ
  arity := FunctionType.arity σ + 1
  call f
    | j :: js => do
      match fromJson? j with
      | .ok a => FunctionType.call (f a) js
      | .error e => throw (IO.userError s!"cannot decode argument {j.compress}: {e}")
    | [] => throw (IO.userError "missing argument")

/-- The result: an effectful computation over the canonical bound interpreter. -/
instance instFunctionTypeEff {effs : List (Type → Type)} {β : Type} [Handlers effs Execution] [ToJson β] :
    FunctionType (Eff effs β) where
  Args := []
  Out := β
  arity := 0
  call m
    | [] => toJson <$> m.handle
    | _ => throw (IO.userError "too many arguments")

/-- One bounded producer step. Wake-ups are absolute Unix milliseconds; the
    continuation is data, never an executable closure. -/
structure ProducerStep where
  values : List Json
  state : Json
  nextCallAt : Option Nat

/-- Producers have ordinary graph arguments followed by the executor's clock
    and optional continuation. Only emitted `B`s become observable values. -/
class ProducerType (σ : Type 1) where
  Args : List Type
  Out : Type
  arity : Nat
  call : σ → List Json → Nat → Option Json → Execution ProducerStep
  validateState : Json → Except String Unit
  validateValue : Json → Except String Unit

instance (priority := high) instProducerTypeStep {S β : Type} {effs : List (Type → Type)}
    [FromJson S] [ToJson S] [FromJson β] [ToJson β] [Handlers effs Execution] :
    ProducerType (Nat → Option S → Eff effs (List β × S × Option Nat)) where
  Args := []
  Out := β
  arity := 0
  call f args now state := do
    unless args.isEmpty do throw (IO.userError "too many producer arguments")
    let state ← match state with
      | none => pure none
      | some value => match (fromJson? value : Except String S) with
        | .ok value => pure (some value)
        | .error error => throw (IO.userError s!"cannot decode producer state: {error}")
    let (values, state, nextCallAt) ← (f now state).handle
    return { values := values.map toJson, state := toJson state, nextCallAt }
  validateState value := (fromJson? value : Except String S).map fun _ => ()
  validateValue value := (fromJson? value : Except String β).map fun _ => ()

instance instProducerTypeArrow {α : Type} {σ : Type 1} [FromJson α] [ProducerType σ] :
    ProducerType (α → σ) where
  Args := α :: ProducerType.Args σ
  Out := ProducerType.Out σ
  arity := ProducerType.arity σ + 1
  call f args now state := do
    match args with
    | value :: rest => match fromJson? value with
      | .ok value => ProducerType.call (f value) rest now state
      | .error error => throw (IO.userError s!"cannot decode producer argument: {error}")
    | [] => throw (IO.userError "missing producer argument")
  validateState := ProducerType.validateState (σ := σ)
  validateValue := ProducerType.validateValue (σ := σ)

/-- The erased, canonically interpreted producer plus its continuation/value
    decoders, used when restoring caller-owned JSON. -/
structure ProducerImpl where
  call : List Json → Nat → Option Json → Execution ProducerStep
  validateState : Json → Except String Unit
  validateValue : Json → Except String Unit

/-- A checked function, ready to run: its name, declared signature and JSON entry
    point. -/
structure FunctionImpl where
  name : String
  signature : String
  arity : Nat
  call : List Json → Execution Json
  producer : Option ProducerImpl := none

/-- Package a Lean function as a served one. -/
def FunctionImpl.ofFn {σ : Type 1} [FunctionType σ] (name signature : String) (f : σ) : FunctionImpl :=
  { name, signature, arity := FunctionType.arity σ, call := FunctionType.call f }

/-- Package a producer. It is executed through graph steps, which own its state
    and schedule, rather than through the single-result function endpoint. -/
def FunctionImpl.ofProducer {σ : Type 1} [ProducerType σ] (name signature : String) (f : σ) : FunctionImpl :=
  { name, signature, arity := ProducerType.arity σ
    call := fun _ => throw (IO.userError "a producer must be called through a graph")
    producer := some { call := ProducerType.call f
                       validateState := ProducerType.validateState (σ := σ)
                       validateValue := ProducerType.validateValue (σ := σ) } }

/-- Values travel through a graph wrapped: `{"ok": v}` for a value,
    `{"error": e}` for a function that failed, `{"blocked": true}` for a function not
    called because an argument has no value. Never as linen's `error`
    notification, which would end the node's stream for good: in a resumed graph a
    node that failed recovers when its inputs change. -/
def okValue (v : Json) : Json := Json.mkObj [("ok", v)]

/-- A function's failure, as a value (see `okValue`). -/
def failedValue (e : String) : Json := Json.mkObj [("error", e)]

/-- A function not called (see `okValue`). -/
def blockedValue : Json := Json.mkObj [("blocked", true)]

/-- The function as linen's reactive graphs call it: its arguments
    are the node's sources, in order (a function of no inputs reads one start
    source, whose value it ignores). It runs only if every argument is a
    value; it never fails as far as linen is concerned (see `okValue`). -/
def FunctionImpl.impl (c : FunctionImpl) (ctx : ExecutionContext := {}) : Impl IO Json := fun vs => do
  let args := vs.filterMap fun v => (v.getObjVal? "ok").toOption
  if args.length != vs.length then return .ok (some blockedValue)
  try pure (.ok (some (okValue (← c.call (if c.arity == 0 then [] else args) { ctx with functionName := c.name }))))
  catch e => pure (.ok (some (failedValue (toString e))))

-- ── The signature check ─────────────────────────────────────────────────────

open Elab Command Term Meta

/-- The effects a function may use, each with its only accepted canonical
    `Handler _ Execution` instance. -/
def allowedEffects : List (Name × Name) :=
   [ (``Control.Monad.Effect.Trace.Trace, ``instExecutionTrace)
   , (``Control.Monad.Effect.Error.Error, ``instExecutionError)
   , (``Control.Monad.Effect.HTTP.HTTP, ``instExecutionHTTP)
  , (``Control.Monad.Effect.FileSystem.FileSystem,
       ``instExecutionFileSystem)
   , (``Control.Monad.Effect.Connector.Connector, ``instExecutionConnector)
   , (``Control.Monad.Effect.PostgreSQL.PostgreSQL, ``instExecutionPostgreSQL)
   , (``Control.Monad.Effect.ObjectStore.ObjectStore, ``instExecutionObjectStore)
   , (``Control.Monad.Effect.SecretStore.SecretStore, ``instExecutionSecretStore) ]

/-- The `Handler`/`Handlers` instances a function's runner may be built from. -/
def allowedInstances : List Name :=
  [``instHandlersNil, ``instHandlersCons, ``instFunctionTypeUnit, ``instFunctionTypeArrow,
    ``instFunctionTypeEff, ``instProducerTypeStep, ``instProducerTypeArrow] ++ allowedEffects.map Prod.snd

/-- The elements of a list literal, reducing it first if it is not one. -/
def listElems (e : Expr) : MetaM (List Expr) := do
  if let some (_, es) := e.listLit? then return es
  let e' ← Meta.reduce e (skipTypes := false)
  match e'.listLit? with
  | some (_, es) => return es
  | none => throwError "the effect row{indentExpr e}\nis not a list of effects"

/-- Refuse a runner assembled from a `Handler`/`Handlers` instance other than
    the allowed ones. -/
def checkInstance (inst : Expr) : MetaM Unit := do
  for c in (← instantiateMVars inst).getUsedConstants do
    let some info := (← getEnv).find? c | continue
    let concl ← forallTelescope info.type fun _ b => pure b.getAppFn.constName?
    if (concl == some ``Handler || concl == some ``Handlers || concl == some ``FunctionType || concl == some ``ProducerType) && !allowedInstances.contains c then
      throwError "the effect handler `{c}` is not one of linen's; a function's effects must run \
        with linen's own handlers"

/-- Audit the executable closure of user code and JSON dictionaries. Safe
    wrappers around unsafe replacement implementations are refused too. The
    kernel still checks types/proofs; this closes Lean's explicit escape hatches. -/
def checkExecutable (roots : List Name) : MetaM Unit := do
  let env ← getEnv
  let trusted (name : Name) := (env.getModuleIdxFor? name).any fun index =>
    trustedModule env.header.moduleNames[index.toNat]!
  -- Initializers execute before a function is called, even if unreachable from
  -- its body. Refuse every untrusted initializer in the imported project.
  for (name, _) in env.constants.toList do
    if !trusted name && ((getInitFnNameFor? env name).isSome || isIOUnitInitFn env name) then
      throwError "project initializer `{name}` is not allowed in a served project"
  let mut todo := roots
  let mut seen : NameSet := {}
  for _ in [0:1000000] do
    let name :: rest := todo | break
    todo := rest
    if seen.contains name then continue
    seen := seen.insert name
    if (`LunDriver.Functions).isPrefixOf name &&
        (env.getModuleIdxFor? name).any (fun index => (`LunDriver.Functions).isPrefixOf env.header.moduleNames[index.toNat]!) then
      continue
    let some info := env.find? name | continue
    if !trusted name then
      if info.isUnsafe || (Compiler.getImplementedBy? env name).isSome || isExtern env name then
        throwError "project declaration `{name}` uses unsafe, implemented_by or extern code"
      if info.isAxiom then throwError "project axiom `{name}` is not allowed"
      for used in info.type.getUsedConstants do
        if [``IO, ``EIO, ``BaseIO, ``Execution, ``ExecutionContext, ``FunctionImpl,
             ``Handler, ``Handlers, ``FunctionType, ``ProducerType, ``ProducerImpl, ``ProducerStep].contains used then
          throwError "project declaration `{name}` reaches the runtime/IO boundary `{used}`"
      if let some value := info.value? (allowOpaque := true) then
        todo := value.getUsedConstants.toList ++ info.type.getUsedConstants.toList ++ todo
    else if let some implementation := Compiler.getImplementedBy? env name then
      unless trusted implementation do todo := implementation :: todo
  unless todo.isEmpty do throwError "the function is too large to audit"

/-- The effect row and result a function's signature ends in:
    `α₁ → … → αₙ → Eff effs β`, non-dependent. -/
def functionRow (sig : Expr) : MetaM (Expr × Expr) :=
  forallTelescopeReducing sig fun xs body => do
    for h : i in [0:xs.size] do
      let x := xs[i].fvarId!
      let later ← (xs.extract (i + 1) xs.size).mapM inferType
      if body.containsFVar x || later.any (·.containsFVar x) then
        throwError "a function's signature cannot be a dependent function type"
    unless body.isAppOfArity ``Eff 2 do
      throwError "a function must return `Eff effs β`, not{indentExpr body}"
    return (body.getArg! 0, body.getArg! 1)

/-- The signature check: `fn` is a function of signature `sig`. -/
def checkFunction (fn : Ident) (sig : Term) (producer : Bool := false) : TermElabM Unit := do
  let expected ← elabType sig
  synthesizeSyntheticMVarsNoPostponing
  let expected ← instantiateMVars expected
  if expected.hasMVar then
    throwError "the signature{indentExpr expected}\nis not fully determined"
  let const ← realizeGlobalConstNoOverloadWithInfo fn
  let info ← getConstInfo const
  if info.isUnsafe then throwError "`{const}` is unsafe"
  -- Elaborate the reference against the signature: implicit arguments (a
  -- polymorphic effect row, say) are instantiated by it.
  let e ← elabTermEnsuringType fn expected
  synthesizeSyntheticMVarsNoPostponing
  let e ← instantiateMVars e
  unless ← isDefEq (← inferType e) expected do
    throwError "`{const}` has type{indentExpr info.type}\nwhich is not the declared signature{indentExpr expected}"
  -- …and nothing else: elaboration may not have wrapped it in a coercion.
  let head ← lambdaTelescope e fun _ b => pure b.getAppFn
  unless head.isConstOf const do
    throwError "`{const}` has type{indentExpr info.type}\nwhich only matches the declared signature \
      through a coercion{indentExpr e}"
  let (row, _) ← functionRow expected
  for eff in ← listElems row do
    let some effName := eff.getAppFn.constName?
      | throwError "the effect{indentExpr eff}\nis not a named effect"
    let some (_, instName) := allowedEffects.find? (·.1 == effName)
      | throwError "the effect `{effName}` is not allowed in a function; allowed: \
          {allowedEffects.map (·.1)}"
    let inst ← synthInstance (mkApp2 (mkConst ``Handler) eff (mkConst ``Execution))
    unless inst.getAppFn.isConstOf instName do
      throwError "the effect `{effName}` resolves to the handler{indentExpr inst}\nnot linen's \
        `{instName}`"
  checkInstance (← synthInstance (mkApp2 (mkConst ``Handlers) row (mkConst ``Execution)))
  if (← collectAxioms const).contains ``sorryAx then
    throwError "`{const}` depends on `sorry`"
  let runner ← synthInstance (mkApp (mkConst (if producer then ``ProducerType else ``FunctionType)) expected)
  checkInstance runner
  checkExecutable (e.getUsedConstants.toList ++ runner.getUsedConstants.toList)

-- ── Graphs: inputs and functions as operators ─────────────────────────────────────

/-- The monad a graph is written in: linen's reactive graphs, over JSON values,
    running functions in `IO`. -/
abbrev GraphM : Type → Type := Reactive IO Json

/-- The first component of every input's label. Not a valid identifier, so
    no function or input name can be mistaken for it. -/
def inputMarker : String := "#input"

/-- The first component of the scope every function application is built in. -/
def functionMarker : String := "#function"

/-- The label of input `name`: `«#input».«name»` (after any enclosing
    `scope`). -/
def inputLabel (name : String) : Name := .str (.str .anonymous inputMarker) name

/-- The scope an application of function `name` is built in. -/
def functionScope (name : String) : Name := .str (.str .anonymous functionMarker) name

/-- The input a subject's label names, if it is an input's. -/
def inputOfLabel : Name → Option String
  | .str (.str _ m) n => if m == inputMarker then some n else none
  | _ => none

/-- The function a generated label belongs to, if it was generated inside a function
    application: `…«#function».«name».kind.k`, `kind` being `fn` for the function
    itself and `subject` for the start source of a function of no inputs. -/
def functionOfLabel (kind : String) : Name → Option String
  | .num (.str (.str (.str _ m) c) k) _ => if m == functionMarker && k == kind then some c else none
  | _ => none

/-- A new input: a subject named `name`, fed by the graph request's
    `inputs.name`. (In `LunDriver.Dsl`, which graph modules open.) -/
def Dsl.input (name : String) (α : Type) : GraphM (Observable α) :=
  Subject.toObservable <$> Reactive.label (inputLabel name) (subject α)

/-- Source constraints are equalities of Lean types, consumed by the input
    constructor. A JSON spelling is never compared to a generated spelling. -/
def constrainedInput (types : String → Type) (names : List String)
    (name : String) (α : Type)
    (_same : names.contains name = false ∨ α = types name := by first | left; decide | right; rfl) : GraphM (Observable α) := Dsl.input name α

/-- The same decoded JSON that will enter the graph, carrying a typed value and
    evidence that the configured source decoder accepted it. -/
structure ValidatedInput (α : Type) [FromJson α] where
  json : Json
  value : α
  decoded : fromJson? json = .ok value

def ValidatedInput.check (α : Type) [FromJson α] (json : Json) : Except String (ValidatedInput α) :=
  match h : (fromJson? json : Except String α) with
  | .ok value => .ok ⟨json, value, h⟩
  | .error error => .error error

/-- A runtime decoder closed over its caller-owned type. The typed witness is
    consumed inside this canonical constructor before JSON enters the graph. -/
structure InputContract where
  validate : Json → Except String Json

def InputContract.ofType (α : Type) [FromJson α] : InputContract :=
  ⟨fun json => (ValidatedInput.check α json).map (·.json)⟩

theorem InputContract.decoder_sound (α : Type) [FromJson α] (json result : Json)
    (h : (InputContract.ofType α).validate json = .ok result) :
    ∃ value : α, fromJson? json = .ok value ∧ result = json := by
  simp only [InputContract.ofType, ValidatedInput.check] at h
  split at h
  · rename_i value decoded
    exact ⟨value, decoded, (Except.ok.inj h).symm⟩
  · contradiction

/-- Apply function `c` to the nodes `ids`: a `combineLatest` over the function's
    implementation, labelled after it. A function of no inputs gets a start
    source of its own instead, which the run feeds once. -/
def applyFunction (c : FunctionImpl) (β : Type) (ids : List NodeId) : GraphM (Observable β) :=
  Reactive.scope (functionScope c.name) do
    let ids ← if c.arity == 0 then (fun s => [s.toObservable.id]) <$> subject Unit else pure ids
    let f ← Reactive.register c.impl
    Reactive.addNode (.combineLatest f) ids β

/-- The operator a graph applies for a function of signature `σ`: one observable
    per input, then the function's output (`Observable α₁ → … → GraphM (Observable β)`,
    or `GraphM (Observable β)` for a function of no inputs). -/
abbrev FunctionRef (σ : Type 1) [FunctionType σ] : Type := Combine IO Json (FunctionType.Args σ) (FunctionType.Out σ)

/-- The operator of the function `c`, of signature `σ`. -/
def functionRef {σ : Type 1} [FunctionType σ] (c : FunctionImpl) : FunctionRef σ :=
  Combine.collect (applyFunction c (FunctionType.Out σ)) [] (FunctionType.Args σ)

/-- The same graph application interface, with the producer's emitted type. -/
abbrev ProducerRef (σ : Type 1) [ProducerType σ] : Type :=
  Combine IO Json (ProducerType.Args σ) (ProducerType.Out σ)

def producerRef {σ : Type 1} [ProducerType σ] (c : FunctionImpl) : ProducerRef σ :=
  Combine.collect (applyFunction c (ProducerType.Out σ)) [] (ProducerType.Args σ)

-- ── Embedded source text ────────────────────────────────────────────────────

/-- Relocate syntax parsed from a string to where that string's content starts
    in the current file, so messages point into the embedded text. -/
def relocate (offset : Nat) (stx : Syntax) : Syntax :=
  let shift (i : SourceInfo) : SourceInfo :=
    match i.getPos?, i.getTailPos? with
    | some p, some q => .synthetic ⟨p.byteIdx + offset⟩ ⟨q.byteIdx + offset⟩
    | _, _ => i
  stx.rewriteBottomUp fun
    | .atom i v => .atom (shift i) v
    | .ident i r v p => .ident (shift i) r v p
    | .node i k as => .node (shift i) k as
    | .missing => .missing

/-- Parse a raw string literal's content as exactly one term, positioned in the
    current file. Request text is embedded this way so it can never be anything
    but the one term it stands for. -/
def parseEmbeddedTerm (lit : StrLit) : CommandElabM Term := do
  let text := lit.getString
  -- The content starts after the opening delimiter (`r#…#"`).
  let delim := match lit.raw with
    | .node _ _ #[.atom _ v] => (v.takeWhile (· != '"')).toString.length + 1
    | _ => 0
  let offset := (lit.raw.getPos?.map (·.byteIdx)).getD 0 + delim
  match Parser.runParserCategory (← getEnv) `term text with
  | .ok stx => pure ⟨relocate offset stx⟩
  | .error e => throwErrorAt lit "cannot parse: {e}"

/-- A dotted name, as a Lean name. -/
def dottedName (s : String) : Name :=
  (s.splitOn ".").foldl Name.mkStr .anonymous

/-- `lun_function "name" := f : r"σ"` — check that `f` is a function of signature `σ`
    (see the module documentation), then define its implementation
    `LunDriver.Impl.name` and the operator graphs apply, `LunDriver.Functions.name`
    (`functionRef`). -/
elab "lun_function " name:str " := " fn:ident " : " sig:str : command => do
  let sigStx ← parseEmbeddedTerm sig
  liftTermElabM (checkFunction fn sigStx)
  let n := dottedName name.getString
  let sigId := mkIdent (`LunDriver.Sig ++ n)
  let implId := mkIdent (`LunDriver.Impl ++ n)
  let functionId := mkIdent (`LunDriver.Functions ++ n)
  let sigText := Syntax.mkStrLit sig.getString
  elabCommand (← `(abbrev $sigId : Type 1 := $sigStx))
  elabCommand (← `(def $implId : LunDriver.FunctionImpl :=
    LunDriver.FunctionImpl.ofFn $name $sigText ($fn : $sigId)))
  elabCommand (← `(def $functionId : LunDriver.FunctionRef $sigId := LunDriver.functionRef $implId))

/-- Check and register a resumable producer using the same closure/effect audit
    as a single-result function. -/
elab "lun_producer " name:str " := " fn:ident " : " sig:str : command => do
  let sigStx ← parseEmbeddedTerm sig
  liftTermElabM (checkFunction fn sigStx true)
  let n := dottedName name.getString
  let sigId := mkIdent (`LunDriver.Sig ++ n)
  let implId := mkIdent (`LunDriver.Impl ++ n)
  let functionId := mkIdent (`LunDriver.Functions ++ n)
  let sigText := Syntax.mkStrLit sig.getString
  elabCommand (← `(abbrev $sigId : Type 1 := $sigStx))
  elabCommand (← `(def $implId : LunDriver.FunctionImpl :=
    LunDriver.FunctionImpl.ofProducer $name $sigText ($fn : $sigId)))
  elabCommand (← `(def $functionId : LunDriver.ProducerRef $sigId := LunDriver.producerRef $implId))

/-- A producer's output constraint applies to each emitted value, not its step
    envelope or continuation. The kernel checks this equality. -/
elab "lun_producer_output " name:str " : " output:str : command => do
  let expected ← parseEmbeddedTerm output
  let signature := mkIdent (`LunDriver.Sig ++ dottedName name.getString)
  let evidence := mkIdent (`LunDriver.OutputContract ++ dottedName name.getString)
  elabCommand (← `(theorem $evidence : LunDriver.ProducerType.Out $signature = $expected := rfl))

/-- A result type owned by the caller, checked against the actual Lean signature. -/
elab "lun_output " name:str " : " output:str : command => do
  let expectedSyntax ← parseEmbeddedTerm output
  liftTermElabM do
    let expected ← elabType expectedSyntax
    synthesizeSyntheticMVarsNoPostponing
    let expected ← instantiateMVars expected
    let sig ← getConstInfo (`LunDriver.Sig ++ dottedName name.getString)
    let some actualSig := sig.value? | throwError "the generated signature has no definition"
    let (_, actual) ← functionRow actualSig
    unless ← isDefEq actual expected do
      throwError "function '{name.getString}' returns{indentExpr actual}\nbut its user-owned output constraint is{indentExpr expected}"
  let signature := mkIdent (`LunDriver.Sig ++ dottedName name.getString)
  let evidence := mkIdent (`LunDriver.OutputContract ++ dottedName name.getString)
  elabCommand (← `(theorem $evidence : LunDriver.FunctionType.Out $signature = $expectedSyntax := rfl))

/-- Generate a typed source constructor from caller-owned constraints. -/
elab "lun_inputs " name:str " := " constraints:str : command => do
  let data ← match Json.parse constraints.getString >>= fun j =>
      (fromJson? j : Except String (List (String × String))) with
    | .ok values => pure values
    | .error e => throwError "invalid input type constraints: {e}"
  let typesId := mkIdent (`LunDriver.Inputs ++ dottedName name.getString ++ `types)
  let inputId := mkIdent (`LunDriver.Inputs ++ dottedName name.getString ++ `input)
  let mut types ← `(Unit)
  for (input, type) in data.reverse do
    let type ← parseEmbeddedTerm ⟨Syntax.mkStrLit type⟩
    types ← `(if name == $(Syntax.mkStrLit input) then $type else $types)
  elabCommand (← `(abbrev $typesId (name : String) : Type := $types))
  let names := Lean.quote (data.map Prod.fst)
  elabCommand (← `(def $(mkIdent (`LunDriver.Inputs ++ dottedName name.getString ++ `names)) : List String := $names))
  elabCommand (← `(def $inputId (name : String) (α : Type)
      (same : ($names : List String).contains name = false ∨ α = $typesId name := by first | left; decide | right; rfl) : LunDriver.GraphM (Control.Reactive.Observable α) :=
    LunDriver.constrainedInput $typesId $names name α same))
  let contractsId := mkIdent (`LunDriver.Inputs ++ dottedName name.getString ++ `contracts)
  let mut contracts ← `(([] : List (String × LunDriver.InputContract)))
  for (input, type) in data.reverse do
    let type ← parseEmbeddedTerm ⟨Syntax.mkStrLit type⟩
    contracts ← `(( $(Syntax.mkStrLit input), LunDriver.InputContract.ofType $type ) :: $contracts)
  elabCommand (← `(def $contractsId : List (String × LunDriver.InputContract) := $contracts))
  liftTermElabM (checkExecutable [(contractsId.getId)])

-- ── The graph check ───────────────────────────────────────────────────────────

/-- What a node of a graph is. -/
inductive NodeKind where
  /-- An input, by name. -/
  | input (name : String)
  /-- The start source of the function of no inputs that reads it (not shown). -/
  | start
  /-- An application of a declared function to the nodes `args` (graph indices). -/
  | apply (name : String) (args : List Nat)
  deriving Inhabited, BEq, Repr, DecidableEq

deriving instance ToJson, FromJson for NodeKind

instance : Quote NodeKind where
  quote
    | .input name => Syntax.mkCApp ``NodeKind.input #[Lean.quote name]
    | .start => mkCIdent ``NodeKind.start
    | .apply name arguments => Syntax.mkCApp ``NodeKind.apply #[Lean.quote name, Lean.quote arguments]

/-- A checked graph, ready to run: its graph, whose every function is a
    declared function's, and what each node is. -/
structure GraphImpl where
  graph : Graph IO Json
  kinds : Array NodeKind
  functions : List FunctionImpl
  inputContracts : List (String × InputContract) := []
  context : ExecutionContext := {}

/-- The builder's primitives, which a graph may reach only through `input` and
    the functions. (`Reactive.fnImpl` is linen ≥ 1.4.0, so it is named, not
    resolved: the runtime still compiles against linen 1.3.0.) -/
def bannedInGraph : List Name :=
  [ ``Reactive.register, ``Reactive.addNode, `Control.Reactive.Reactive.fnImpl, ``Reactive.fn
  , ``Builder.mk, ``Graph.mk, ``Graph.rebind, ``Operator.mk, ``Operator.splice
  -- A labelled raw subject could masquerade as a checked source. Observable
  -- and Subject constructors are already private in Linen.
  , ``Reactive.subject ]

/-- `g` as a graph of the declared `functions`, or what is wrong with it: every node
    is an input or an application of a declared function (by its function's label)
    to as many nodes as the function has inputs, and every function is a declared
    function's — which then replaces it, whatever the graph held. Input names are
    distinct because labels are. -/
def GraphImpl.ofGraph (functions : List FunctionImpl) (g : Graph IO Json) : Except String GraphImpl := do
  let functionOf (name : String) : Option FunctionImpl := functions.find? (·.name == name)
  let fnImpls ← g.fnLabels.toList.mapM fun l => match functionOfLabel "fn" l >>= functionOf with
    | some c => pure c
    | none => throw s!"the function `{l}` is not a declared function; a graph may apply only the \
        declared functions"
  let describe (i : Nat) : String := s!"node {i} (`{g.label ⟨i⟩}`)"
  let mut kinds : Array NodeKind := #[]
  let mut startsRead : List Nat := []
  for h : i in [0:g.nodes.size] do
    let n := g.nodes[i]
    match n.op with
    | .subject =>
      if let some name := inputOfLabel (g.label ⟨i⟩) then kinds := kinds.push (.input name)
      else if (functionOfLabel "subject" (g.label ⟨i⟩)).isSome then kinds := kinds.push .start
      else throw s!"{describe i} is a subject that is not an `input`"
    | .combineLatest f =>
      let some c := fnImpls[f.idx]? | throw s!"{describe i} applies an unknown function"
      let args := n.args.map (·.idx)
      let isStart (j : Nat) : Bool := kinds[j]? == some .start
      if c.arity == 0 then
        match args with
        | [j] =>
          unless isStart j && !startsRead.contains j do
            throw s!"{describe i} applies '{c.name}', which takes no input, to a node"
          startsRead := j :: startsRead
          kinds := kinds.push (.apply c.name [])
        | _ => throw s!"{describe i} applies '{c.name}', which takes no input, to {args.length} nodes"
      else
        unless args.length == c.arity do
          throw s!"{describe i} applies '{c.name}' to {args.length} arguments; it takes {c.arity}"
        if args.any isStart then throw s!"{describe i} applies '{c.name}' to a start source"
        kinds := kinds.push (.apply c.name args)
    | op => throw s!"{describe i} uses the `{op.name}` operator; a graph may only apply the \
        declared functions to inputs and to each other"
  for h : i in [0:kinds.size] do
    if kinds[i] == .start && !startsRead.contains i then throw s!"{describe i} is not read"
  let fns : Array (Impl IO Json) := Array.ofFn (n := g.fns.size) fun k =>
      ((fnImpls[k.val]?).map (fun c => c.impl)).getD fun _ => pure (.error "unknown function")
  let graph : Graph IO Json :=
    ⟨g.nodes, fns, g.labels, g.fnLabels,
      by rw [Array.size_ofFn]; exact g.wellFormed, by rw [Array.size_ofFn]; exact g.labelled⟩
  return { graph, kinds, functions }

/-- Bind every function of a graph to the same immutable runtime context. -/
def GraphImpl.withContext (d : GraphImpl) (ctx : ExecutionContext) : GraphImpl :=
  let fns : Array (Impl IO Json) := Array.ofFn (n := d.graph.fns.size) fun k =>
    ((d.graph.fnLabels[k.val]?).bind (functionOfLabel "fn") >>= fun name =>
      d.functions.find? (·.name == name)).map (fun c => c.impl ctx)
      |>.getD fun _ => pure (.error "unknown function")
  { d with context := ctx, graph := ⟨d.graph.nodes, fns, d.graph.labels, d.graph.fnLabels,
      by rw [Array.size_ofFn]; exact d.graph.wellFormed,
      by rw [Array.size_ofFn]; exact d.graph.labelled⟩ }

/-- Build a graph program and check it (`GraphImpl.ofGraph`). -/
def GraphImpl.ofReactive (functions : List FunctionImpl) (r : GraphM Unit) : Except String GraphImpl := do
  let dup := s!"two nodes are labelled `{inputMarker}."
  let (_, g) ← r.build.mapError fun e =>
    if e.startsWith dup then s!"the input '{((e.drop dup.length).takeWhile (· != '`')).toString}' \
      is declared twice" else e
  GraphImpl.ofGraph functions g

/-- The error of a graph, if it has one: what the check evaluates. -/
def GraphImpl.error? (d : Except String GraphImpl) : Option String :=
  match d with
  | .ok _ => none
  | .error e => some e

/-- Check declarations against the graph that will actually run. Every declared
    cell has one application, with exactly the named arguments in their order. -/
def GraphImpl.dependencyError? (d : GraphImpl) (expected : List (String × List String)) : Option String := Id.run do
  for (name, args) in expected do
    let applications := d.kinds.toList.filterMap fun
      | .apply n ids => if n == name then some ids else none
      | _ => none
    unless applications.length == 1 do
      return some s!"cell '{name}' must have exactly one application in the graph"
    let actual := (applications.headD []).map fun i => match d.kinds[i]? with
      | some (.input n) | some (.apply n _) => n
      | _ => "(unknown)"
    unless actual == args do
      return some s!"cell '{name}' reads {actual}, but its declared inputs are {args}"
  return none

def dependencyError (graph : Except String GraphImpl) (expected : List (String × List String)) : Option String :=
  match graph with
  | .ok d => d.dependencyError? expected
  | .error e => some e

/-- The actual graph's named ordered arguments, independent of generated text. -/
def layoutApplications (kinds : Array NodeKind) (name : String) : List (List Nat) :=
  kinds.toList.filterMap fun
    | .apply cell arguments => if cell == name then some arguments else none
    | _ => none

def layoutArgumentNames (kinds : Array NodeKind) (arguments : List Nat) : List String :=
  arguments.map fun index => match (kinds[index]? : Option NodeKind) with
    | some (.input name) | some (.apply name _) => name
    | _ => "(unknown)"

/-- Kernel-level caller-owned wiring contract: exactly one application and the
    exact direct argument names, in their declared order. -/
def LayoutDependencies (kinds : Array NodeKind) (expected : List (String × List String)) : Prop :=
  ∀ entry ∈ expected, (layoutApplications kinds entry.1).length = 1 ∧
    layoutArgumentNames kinds ((layoutApplications kinds entry.1).headD []) = entry.2

instance (kinds : Array NodeKind) (expected : List (String × List String)) :
    Decidable (LayoutDependencies kinds expected) := List.decidableBAll _ _

structure WiringSpec where
  layout : Array NodeKind
  expected : List (String × List String)
  valid : LayoutDependencies layout expected

structure BoundWiring (spec : WiringSpec) where
  private mk ::
  graph : GraphImpl
  sameLayout : graph.kinds = spec.layout

theorem BoundWiring.named_arguments (bound : BoundWiring spec) :
    LayoutDependencies bound.graph.kinds spec.expected := by
  rw [bound.sameLayout]
  exact spec.valid

def BoundWiring.check? (spec : WiringSpec) (graph : GraphImpl) : Option (BoundWiring spec) :=
  if h : graph.kinds = spec.layout then some ⟨graph, h⟩ else none

/-- Runtime must consume the layout-equality witness before returning the same
    graph whose named wiring was proved in the kernel. -/
def bindWiring (graph : Except String GraphImpl) (spec : WiringSpec) : Except String GraphImpl := do
  let graph ← graph
  let some bound := BoundWiring.check? spec graph | throw "the runtime graph differs from its proved wiring layout"
  return bound.graph

/-- Each configured source occurs exactly once in the actual graph. -/
def SourceLayout (kinds : Array NodeKind) (names : List String) : Prop :=
  ∀ name ∈ names, (kinds.toList.filter (fun kind => kind == .input name)).length = 1

instance (kinds : Array NodeKind) (names : List String) : Decidable (SourceLayout kinds names) :=
  List.decidableBAll _ _

structure SourceSpec where
  layout : Array NodeKind
  names : List String
  valid : SourceLayout layout names

structure BoundSources (spec : SourceSpec) where
  private mk ::
  graph : GraphImpl
  sameLayout : graph.kinds = spec.layout

theorem BoundSources.present (bound : BoundSources spec) : SourceLayout bound.graph.kinds spec.names := by
  rw [bound.sameLayout]
  exact spec.valid

def BoundSources.check? (spec : SourceSpec) (graph : GraphImpl) : Option (BoundSources spec) :=
  if h : graph.kinds = spec.layout then some ⟨graph, h⟩ else none

def bindSources (graph : Except String GraphImpl) (spec : SourceSpec) : Except String GraphImpl := do
  let graph ← graph
  let some bound := BoundSources.check? spec graph | throw "the runtime graph differs from its proved source layout"
  return bound.graph

unsafe def evalKindsUnsafe (name : Name) : TermElabM (Array NodeKind) := do
  let graph ← evalConst (Except String GraphImpl) name
  match graph with
  | .ok graph => return graph.kinds
  | .error error => throwError "invalid graph: {error}"
@[implemented_by evalKindsUnsafe] opaque evalKinds (name : Name) : TermElabM (Array NodeKind)

unsafe def evalNamesUnsafe (name : Name) : TermElabM (List String) := evalConst (List String) name
@[implemented_by evalNamesUnsafe] opaque evalNames (name : Name) : TermElabM (List String)

unsafe def evalErrorUnsafe (n : Name) : TermElabM (Option String) := evalConst (Option String) n
@[implemented_by evalErrorUnsafe] opaque evalError (n : Name) : TermElabM (Option String)

/-- The function operators the driver generated: in `LunDriver.Functions`, defined by
    one of the generated `LunDriver.Functions.*` modules. -/
def isFunctionRef (env : Environment) (c : Name) : Bool :=
  let generated := match env.getModuleIdxFor? c with
    | some idx => (`LunDriver.Functions).isPrefixOf (env.header.moduleNames[idx.toNat]!)
    | none => false
  generated && (`LunDriver.Functions).isPrefixOf c &&
    ((env.find? c).map (fun info => info.type.getAppFn.isConstOf ``FunctionRef ||
      info.type.getAppFn.isConstOf ``ProducerRef)).getD false

/-- The graph check: the definition `programName` uses none of the builder's
    primitives and no `sorry` (see the module documentation), and the error
    `errorName` evaluates to — its graph checked by `GraphImpl.ofGraph` — is none. -/
def checkGraph (programName errorName : Name) (inputConstructor : Option Name := none) : TermElabM Unit := do
  let env ← getEnv
  checkExecutable [programName]
  if (← collectAxioms programName).contains ``sorryAx then throwError "the graph depends on `sorry`"
  -- Walk every constant the definition reaches, through everything that is
  -- not library code, stopping at the generated function operators.
  let trusted (c : Name) : Bool := match env.getModuleIdxFor? c with
    | some idx => trustedModule (env.header.moduleNames[idx.toNat]!)
    | none => false
  let mut todo : List Name := [programName]
  let mut seen : NameSet := {}
  -- A bound, not fuel: no graph definition reaches a million constants.
  for _ in [0:1000000] do
    match todo with
    | [] => break
    | c :: rest =>
      todo := rest
      if seen.contains c then continue
      seen := seen.insert c
      let some info := env.find? c | continue
      if info.isUnsafe then throwError "the graph uses the unsafe `{c}`"
      let some v := info.value? (allowOpaque := true) | continue
      for u in v.getUsedConstants ++ info.type.getUsedConstants do
        if inputConstructor.isSome && (u == ``Dsl.input || u == ``constrainedInput) then
          throwError "a constrained graph must use its checked input constructor"
        if bannedInGraph.contains u then
          throwError "the graph uses `{u}` (in `{c}`); a graph may build nodes only with `input` \
            and the declared functions"
        unless trusted u || isFunctionRef env u || inputConstructor == some u || seen.contains u do
          todo := u :: todo
  unless todo.isEmpty do throwError "the graph is too large to check"
  if let some e ← evalError errorName then throwError "invalid graph: {e}"

declare_syntax_cat lunInputConstraint
syntax " using_input " ident : lunInputConstraint

/-- `lun_graph "name" := r#"program"#` — define the graph `LunDriver.Programs.name.«#program»`
    from a `Reactive` program over the declared functions (and, checked,
    `LunDriver.Graphs.name`), then check it. -/
elab "lun_graph " name:str inputDecl:(lunInputConstraint)? " := " prog:str : command => do
  let t ← parseEmbeddedTerm prog
  let n := dottedName name.getString
  -- A public graph/function name may coincide. An internal final component
  -- prevents Lean from resolving an application as this definition's recursion.
  let programName := Name.str (`LunDriver.Programs ++ n) "#program"
  let graphName := `LunDriver.Graphs ++ n
  let errorName := `LunDriver.GraphErrors ++ n
  let programId := mkIdent programName
  let graphId := mkIdent graphName
  let errorId := mkIdent errorName
  let before := (← get).messages.toList.length
  elabCommand (← `(def $programId : LunDriver.GraphM Unit := Functor.discard ($t)))
  -- An ill-typed program is already reported; checking its error-recovery
  -- stand-in would only add a spurious `sorry`.
  if (← get).messages.toList.drop before |>.any (·.severity == .error) then return
  let contracts : Term ← if inputDecl.isSome then pure (mkIdent (`LunDriver.Inputs ++ n ++ `contracts)) else `([])
  elabCommand (← `(def $graphId : Except String LunDriver.GraphImpl :=
    (LunDriver.GraphImpl.ofReactive $(mkIdent `LunDriver.functionImpls) $programId).map fun graph =>
      { graph with inputContracts := $contracts }))
  elabCommand (← `(def $errorId : Option String := LunDriver.GraphImpl.error? $graphId))
  let inputConstructor := inputDecl.map fun stx => stx.raw[1].getId
  withRef prog <| liftTermElabM (checkGraph programName errorName inputConstructor)
  if inputDecl.isSome then
    let layout ← liftTermElabM (evalKinds graphName)
    let names ← liftTermElabM (evalNames (`LunDriver.Inputs ++ n ++ `names))
    for source in names do
      unless (layout.toList.filter (fun kind => kind == .input source)).length == 1 do
        throwError "configured input '{source}' must occur exactly once in the graph"
    let snapshot := Lean.quote layout
    let names := Lean.quote names
    let evidence := mkIdent (`LunDriver.SourceContract ++ n)
    elabCommand (← `(def $evidence : LunDriver.SourceSpec :=
      { layout := $snapshot, names := $names, valid := by decide }))
    let bound := mkIdent (`LunDriver.SourceConstrainedGraphs ++ n)
    elabCommand (← `(def $bound : Except String LunDriver.GraphImpl := LunDriver.bindSources $graphId $evidence))

/-- Caller-owned named wiring constraints; JSON is data, never generated code. -/
elab "lun_dependencies " name:str " := " constraints:str : command => do
  let data ← match (Json.parse constraints.getString >>= fun j => (fromJson? j : Except String (List (String × List String)))) with
    | .ok values => pure values
    | .error e => throwError "invalid dependency constraints: {e}"
  let graphName := dottedName name.getString
  let graphId := mkIdent (if (← getEnv).contains (`LunDriver.SourceConstrainedGraphs ++ graphName)
    then `LunDriver.SourceConstrainedGraphs ++ graphName else `LunDriver.Graphs ++ graphName)
  let errorName := `LunDriver.DependencyErrors ++ dottedName name.getString
  let literal := Lean.quote data
  elabCommand (← `(def $(mkIdent errorName) : Option String :=
    LunDriver.dependencyError $graphId $literal))
  liftTermElabM do
    if let some e ← evalError errorName then throwError "invalid cell dependencies: {e}"
  let layout ← liftTermElabM (evalKinds graphId.getId)
  let snapshot := Lean.quote layout
  let evidence := mkIdent (`LunDriver.WiringContract ++ dottedName name.getString)
  elabCommand (← `(def $evidence : LunDriver.WiringSpec :=
    { layout := $snapshot, expected := $literal, valid := by decide }))
  let bound := mkIdent (`LunDriver.ConstrainedGraphs ++ dottedName name.getString)
  elabCommand (← `(def $bound : Except String LunDriver.GraphImpl := LunDriver.bindWiring $graphId $evidence))

-- ── Stateless graph execution ────────────────────────────────────────────────

/-- The nodes shown: inputs and function applications, not start sources. Their
    positions in this list are the ids a graph's nodes are known by. -/
def GraphImpl.shown (d : GraphImpl) : List Nat :=
  (List.range d.kinds.size).filter fun i => d.kinds[i]? != some .start

/-- The id of graph node `i` among the shown nodes. -/
def GraphImpl.idOf (d : GraphImpl) (i : Nat) : Nat := (d.shown.idxOf? i).getD i

/-- One node, for `describe` and graph results. -/
def GraphImpl.nodeJson (d : GraphImpl) (i : Nat) : List (String × Json) :=
  match (d.kinds[i]? : Option NodeKind) with
  | some (.input name) => [("id", d.idOf i), ("input", name)]
  | some (.apply c args) => [("id", d.idOf i), ("function", c), ("args", toJson (args.map d.idOf))]
  | _ => [("id", d.idOf i)]

/-- The nodes a node reads (graph indices). -/
def GraphImpl.argsOf (d : GraphImpl) (i : Nat) : List Nat :=
  match (d.kinds[i]? : Option NodeKind) with
  | some (.apply _ args) => args
  | _ => []

/-- The graph index of input `name`. -/
def GraphImpl.inputIndex? (d : GraphImpl) (name : String) : Option Nat :=
  (List.range d.kinds.size).find? fun i => d.kinds[i]? == some (.input name)

/-- The graph's inputs, by name. -/
def GraphImpl.inputNames (d : GraphImpl) : List String :=
  d.kinds.toList.filterMap fun | .input n => some n | _ => none

/-- A suspended producer carries only typed JSON and its next wake-up. -/
structure ProducerContinuation where
  value : Json
  nextCallAt : Nat
  deriving ToJson, FromJson

/-- All mutable execution data belongs to the caller. `pending` retains burst
    emissions when the per-call work budget is reached. No authority is stored. -/
structure GraphState where
  contract : String := runtimeContract
  build : String
  graphName : String
  identity : Json
  now : Nat
  outcomes : Array Json
  continuations : Array (Option ProducerContinuation)
  pending : List (Nat × Json) := []
  deriving ToJson, FromJson

/-- Bind state to the exact labelled graph and declared function signatures. -/
def GraphImpl.stateIdentity (d : GraphImpl) : Json :=
  Json.mkObj [("kinds", toJson d.kinds), ("labels", toJson (d.graph.labels.map toString)),
    ("functions", toJson (d.functions.map fun c => (c.name, c.signature, c.producer.isSome)))]

def GraphImpl.producerAt (d : GraphImpl) (i : Nat) : Option ProducerImpl := do
  let .apply name _ ← d.kinds[i]? | none
  (← d.functions.find? (·.name == name)).producer

/-- Validate the complete state before running any effects. State is data from
    the caller's database, never a source of permissions or runtime context. -/
def GraphState.ofJson (d : GraphImpl) (build graphName : String) (j : Json) : Except String GraphState := do
  let s : GraphState ← fromJson? j
  unless s.contract == runtimeContract && s.build == build && s.graphName == graphName &&
      s.identity == d.stateIdentity && s.outcomes.size == d.graph.size &&
      s.continuations.size == d.graph.size do
    throw "the state is not one of this compiled graph's"
  for i in [0:s.outcomes.size] do
    let outcome := s.outcomes[i]!
    if outcome != Json.null then
      let fields ← outcome.getObj?
      unless fields.size == 1 do throw "invalid node outcome in graph state"
      if let .ok value := outcome.getObjVal? "output" then
        if let some producer := d.producerAt i then producer.validateValue value
        if let some (.input name) := d.kinds[i]? then
          if let some contract := d.inputContracts.lookup name then discard <| contract.validate value
      else if (outcome.getObjValAs? String "error").isOk then pure ()
      else if let .ok skipped := outcome.getObjValAs? Nat "skipped" then
        unless (d.argsOf i).any (fun arg => d.idOf arg == skipped) do throw "invalid skipped node in graph state"
      else throw "invalid node outcome in graph state"
    if let some continuation := s.continuations[i]! then
      let some producer := d.producerAt i | throw "a non-producer has a continuation"
      producer.validateState continuation.value
  for (i, value) in s.pending do
    let some producer := d.producerAt i | throw "a pending emission is not from a producer"
    producer.validateValue value
  return s

/-- A node's outcome, from the value it last emitted: `{"output": v}`, its
    function's `{"error": e}`, or `{"skipped": j}` (`j` its first argument without
    a value); `outcomes` holds the outcomes of the nodes before it. -/
def GraphImpl.outcomeOf (d : GraphImpl) (outcomes : Array Json) (i : Nat) (v : Json) : Json :=
  match v.getObjVal? "ok", v.getObjValAs? String "error" with
  | .ok out, _ => Json.mkObj [("output", out)]
  | _, .ok e => Json.mkObj [("error", e)]
  | _, _ =>
    let hasValue (j : Nat) : Bool := ((outcomes[j]?).bind (·.getObjVal? "output" |>.toOption)).isSome
    match (d.argsOf i).find? (!hasValue ·) with
    | some j => Json.mkObj [("skipped", d.idOf j)]
    | none => Json.mkObj [("error", "no value")]

/-- The value an input is fed: its value, or (`none`) a missing input's error. -/
def inputValue (v : Option Json) (name : String) : Json :=
  match v with
  | some v => okValue v
  | none => failedValue s!"missing input '{name}'"

/-- Decode all supplied sources before any node can execute. Failed updates
    therefore produce no partial effects and do not mutate stored state. -/
def GraphImpl.checkedInput (d : GraphImpl) (name : String) (json : Json) : Except String Json := do
  match d.inputContracts.lookup name with
  | none => return okValue json
  | some contract =>
    let validated ← contract.validate json |>.mapError (fun error => s!"input '{name}' violates its configured type: {error}")
    return okValue validated

/-- A fresh caller-owned state. -/
def GraphImpl.initial (d : GraphImpl) (build graphName : String) : GraphState :=
  { build, graphName, identity := d.stateIdentity, now := 0
    outcomes := Array.replicate d.graph.size Json.null
    continuations := Array.replicate d.graph.size none }

/-- Start sources are fed once, only when the request has no previous state. -/
def GraphImpl.starts (d : GraphImpl) : List (Nat × Json) :=
  (List.range d.kinds.size).filterMap fun i =>
    if d.kinds[i]? == some .start then some (i, okValue Json.null) else none

/-- The occurrences for `{"name": value, …}`: every name must be an input. -/
def GraphImpl.occurrencesOf (d : GraphImpl) (inputs : Json) : Except String (List (Nat × Json)) := do
  let kvs ← match inputs with
    | .obj kvs => pure kvs.toList
    | .null => pure []
    | _ => throw "\"inputs\" must be an object"
  kvs.mapM fun (name, v) => match d.inputIndex? name with
    | some i => do return (i, ← d.checkedInput name v)
    | none => throw s!"the graph has no input named '{name}'; its inputs: {d.inputNames}"

/-- Adoption may retain the source as an editable error when its historic JSON
    no longer decodes. An invalid value is never fed as a successful input. -/
def GraphImpl.recoveredOccurrencesOf (d : GraphImpl) (inputs : Json) : Except String (List (Nat × Json)) := do
  let fields ← inputs.getObj?
  fields.toList.mapM fun (name, value) => do
    let some index := d.inputIndex? name | throw s!"the graph has no input named '{name}'"
    let checked := match d.checkedInput name value with
      | .ok checked => checked
      | .error error => failedValue error
    return (index, checked)

/-- The shown nodes `is`, each with its outcome. -/
def GraphImpl.nodesJson (d : GraphImpl) (st : GraphState) (is : List Nat) : Json :=
  Json.arr <| is.toArray.map fun i =>
    let result := match st.outcomes[i]? with
      | some (.obj kvs) => kvs.toList
      | _ => []
    Json.mkObj (d.nodeJson i ++ result)

/-- Wrap a stored outcome for the canonical function interpreter. -/
def outcomeValue (outcome : Json) : Json :=
  match outcome.getObjVal? "output", outcome.getObjValAs? String "error" with
  | .ok value, _ => okValue value
  | _, .ok error => failedValue error
  | _, _ => blockedValue

/-- Execute one node. An argument event restarts a producer and cancels its
    older queued emissions; a scheduled wake-up resumes its continuation. -/
def GraphImpl.executeNode (d : GraphImpl) (st : GraphState) (i now : Nat)
    (resume : Bool := false) : IO (GraphState × List Json) := do
  let some (.apply name ids) := d.kinds[i]? | return (st, [])
  let some c := d.functions.find? (·.name == name) | return (st, [])
  let continuation := if resume then (st.continuations[i]!).map (·.value) else none
  let st := { st with continuations := st.continuations.set! i none
                      pending := if resume then st.pending else st.pending.filter (fun item => item.1 != i) }
  if ids.any (fun arg => st.outcomes[arg]! == Json.null) then return (st, [])
  let args := ids.map fun arg => outcomeValue st.outcomes[arg]!
  if args.any (fun value => !(value.getObjVal? "ok").isOk) then return (st, [blockedValue])
  match c.producer with
  | none =>
    let result ← c.impl d.context args
    return (st, match result with
      | .ok (some value) => [value]
      | .ok none => []
      | .error error => [failedValue error])
  | some producer =>
    try
      let step ← producer.call (args.filterMap fun value => (value.getObjVal? "ok").toOption)
        now continuation { d.context with functionName := c.name }
      if let some next := step.nextCallAt then
        unless next > now do throw (IO.userError "a producer's nextCallAt must be after now")
      let next := step.nextCallAt.map fun nextCallAt => { value := step.state, nextCallAt : ProducerContinuation }
      return ({ st with continuations := st.continuations.set! i next }, step.values.map okValue)
    catch error => return (st, [failedValue (toString error)])

/-- Record a changed outcome immediately. Repeated changes to one node are
    retained, including a burst that returns to its original value. -/
def GraphImpl.record (d : GraphImpl) (st : GraphState) (i now : Nat) (value : Json) : GraphState × List Json :=
  let outcome := d.outcomeOf st.outcomes i value
  let changed := if st.outcomes[i]! == outcome || d.kinds[i]? == some .start then []
    else [Json.mkObj (d.nodeJson i ++ ((outcome.getObj?).toOption.map (·.toList)).getD [] ++
      [("timestamp", toJson now)])]
  ({ st with outcomes := st.outcomes.set! i outcome }, changed)

/-- Propagate one occurrence in topological order. A diamond sees both newly
    computed branches before its join runs. Further producer outputs are queued
    as separate occurrences, each of which traverses downstream nodes. -/
def GraphImpl.propagate (d : GraphImpl) (initial : GraphState) (i now : Nat) (value : Json) :
    IO (GraphState × List Json) := do
  let (initial, first) := d.record initial i now value
  let mut st := initial
  let mut changed := first
  let mut emitted := (Array.replicate d.graph.size false).set! i true
  for j in [i + 1:d.graph.size] do
    if !(d.graph.nodes[j]!.args.any (fun arg => emitted[arg.idx]!)) then continue
    let (updated, values) ← d.executeNode st j now
    st := updated
    let value :: rest := values | continue
    let (updated, changes) := d.record st j now value
    st := { updated with pending := updated.pending ++ (rest.filterMap fun value =>
      (value.getObjVal? "ok").toOption.map (j, ·)) }
    changed := changed ++ changes
    emitted := emitted.set! j true
  return (st, changed)

/-- The earliest scheduled producer, ties broken by topological node order. -/
def GraphState.nextProducer (st : GraphState) : Option (Nat × Nat) :=
  (List.range st.continuations.size).foldl (fun best i =>
    match st.continuations[i]!, best with
    | some next, some (_, time) => if next.nextCallAt < time then some (i, next.nextCallAt) else best
    | some next, none => some (i, next.nextCallAt)
    | none, _ => best) none

/-- A pending burst needs an immediate call; otherwise wake at the earliest
    continuation, or wait for external input when no timed work remains. -/
def GraphState.nextCallAt (st : GraphState) : Option Nat :=
  if !st.pending.isEmpty then some st.now
  else st.nextProducer.map fun (_, time) => max st.now time

/-- Bound latency by processing at most this many queued occurrences/wake-ups
    per call. Remaining work travels in the returned state, not in a worker. -/
def graphStepBudget : Nat := 256

/-- Execute a graph step. Fresh inputs take precedence over older scheduled
    work. Every effect uses this request's context, including on a wake-up. -/
def runGraph (d : GraphImpl) (req : Json) (traceLog : Option (IO.Ref BoundedTrace) := none) : IO (Except String Json) := do
  let ctx ← match ExecutionContext.ofRequest req traceLog with | .ok c => pure c | .error e => return .error e
  let build := (req.getObjValAs? String "_build").toOption.getD ""
  let graphName := (req.getObjValAs? String "_graph").toOption.getD ""
  let previous ← match req.getObjVal? "state" with
    | .error _ | .ok .null => pure none
    | .ok value => match GraphState.ofJson d build graphName value with
      | .ok value => pure (some value)
      | .error error => return .error error
  let now ← match req.getObjVal? "now" with
    | .error _ => pure ((← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000)
    | .ok value => match (fromJson? value : Except String Nat) with
      | .ok now => pure now
      | .error _ => return .error "now must be a Unix timestamp in milliseconds"
  let initial := previous.getD (d.initial build graphName)
  if now < initial.now then return .error "now cannot precede the state's timestamp"
  let inputs := (req.getObjVal? "inputs").toOption.getD (Json.mkObj [])
  let recover := (req.getObjValAs? Bool "recoverInputs").toOption == some true
  let occurrences ← match (if recover then d.recoveredOccurrencesOf inputs else d.occurrencesOf inputs) with
    | .ok values => pure values
    | .error error => return .error error
  let d := d.withContext ctx
  let mut st := { initial with now }
  let mut changed := []
  for (i, value) in (if previous.isNone then d.starts else []) ++ occurrences do
    if previous.isSome && st.outcomes[i]! == d.outcomeOf st.outcomes i value then continue
    let (updated, changes) ← d.propagate st i now value
    st := updated
    changed := changed ++ changes
  for _ in [0:graphStepBudget] do
    if let (i, value) :: rest := st.pending then
      let (updated, changes) ← d.propagate { st with pending := rest } i now (okValue value)
      st := updated
      changed := changed ++ changes
    else
      let some (i, time) := st.nextProducer | break
      if time > now then break
      let (updated, values) ← d.executeNode st i now true
      st := updated
      let value :: rest := values | continue
      st := { st with pending := st.pending ++ (rest.filterMap fun value =>
        (value.getObjVal? "ok").toOption.map (i, ·)) }
      let (updated, changes) ← d.propagate st i now value
      st := updated
      changed := changed ++ changes
  return .ok (Json.mkObj [("state", toJson st), ("nodes", d.nodesJson st d.shown),
    ("changed", toJson changed), ("nextCallAt", toJson st.nextCallAt)])

/-- The build's functions and graphs, with each graph's structure: its nodes, its
    sources (nodes reading none) and its sinks (nodes none reads). -/
def describe (functions : List FunctionImpl) (graphs : List (String × GraphImpl)) : Json :=
  Json.mkObj
    [ ("runtimeContract", Json.str runtimeContract)
    , ("functions", Json.arr (functions.map fun c => Json.mkObj
        [("name", c.name), ("signature", c.signature), ("arity", c.arity),
         ("producer", toJson c.producer.isSome)]).toArray)
    , ("graphs", Json.arr (graphs.map fun (name, d) =>
        let read := d.shown.flatMap d.argsOf
        Json.mkObj
          [ ("name", name)
          , ("inputs", toJson d.inputNames)
          , ("nodes", Json.arr (d.shown.map fun i => Json.mkObj (d.nodeJson i)).toArray)
          , ("sources", toJson ((d.shown.filter fun i => (d.argsOf i).isEmpty).map d.idOf))
          , ("sinks", toJson ((d.shown.filter fun i => !read.contains i).map d.idOf)) ]).toArray) ]

-- ── The protocol ────────────────────────────────────────────────────────────

/-- The arguments of one call, from its input: nothing for a function of no
    inputs, the value itself for one input, a JSON array of `arity` values
    otherwise. -/
def argsOf (arity : Nat) (input : Option Json) : Except String (List Json) :=
  match arity, input with
  | 0, _ => .ok []
  | 1, some j => .ok [j]
  | n, some (.arr js) =>
    if js.size == n then .ok js.toList else .error s!"expected an array of {n} arguments"
  | 1, none => .error "missing input"
  | n, _ => .error s!"expected an array of {n} arguments"

/-- `{"output": v}` or `{"error": message}`. -/
def outcomeJson (r : Except String Json) : Json :=
  match r with
  | .ok v => Json.mkObj [("output", v)]
  | .error e => Json.mkObj [("error", e)]

/-- Run a function, turning every failure into an `Except`. -/
def FunctionImpl.run (c : FunctionImpl) (input : Option Json) (ctx : ExecutionContext := {}) : IO (Except String Json) := do
  match argsOf c.arity input with
  | .error e => pure (.error e)
  | .ok args =>
    try pure (.ok (← c.call args { ctx with functionName := c.name })) catch e => pure (.error (toString e))

/-- A function request: `{"input": x}` (one call; omitted for a function of no
    inputs) or `{"inputs": [x₁, x₂, …]}` (one call per element). -/
def runFunction (c : FunctionImpl) (req : Json) (traceLog : Option (IO.Ref BoundedTrace) := none) : IO (Except String Json) := do
  let ctx ← match ExecutionContext.ofRequest req traceLog with | .ok c => pure c | .error e => return .error e
  match req.getObjVal? "inputs" with
  | .ok (.arr xs) =>
    let outs ← xs.mapM fun x => outcomeJson <$> c.run (some x) ctx
    pure (.ok (Json.mkObj [("outputs", Json.arr outs)]))
  | .ok _ => pure (.error "\"inputs\" must be an array")
  | .error _ =>
    let input := (req.getObjVal? "input").toOption
    pure (.ok (outcomeJson (← c.run input ctx)))

/-- Dispatch using immutable checked graph templates. Context and graph state
    are taken exclusively from this request; withContext returns a fresh graph. -/
def runCommand (functions : List FunctionImpl) (graphs : List (String × Except String GraphImpl))
    (kind name : String) (req : Json) (log : Option (IO.Ref BoundedTrace) := none) : IO (Except String Json) := do
  if kind == "warm" then return .ok (Json.mkObj [("runtimeContract", runtimeContract)])
  if kind == "function" then
    match functions.find? (·.name == name) with
    | none => return .error s!"no function named '{name}'"
    | some c => return ← runFunction c req log
  match graphs.lookup name with
  | none => return .error s!"no graph named '{name}'"
  | some (.error e) => return .error s!"graph '{name}': {e}"
  | some (.ok d) =>
    match kind with
    | "graph" => runGraph d (req.setObjVal! "_graph" (toJson name)) log
    | _ => return .error s!"unknown command '{kind}'"

/-- Kill this worker's whole process group if its parent stops refreshing the
    private lease. This also works for abrupt parent death and blocked effects. -/
def superviseParent (leaseFile : String) : IO Unit := do
  repeat
    IO.sleep 1000
    let healthy ← try
      let text ← IO.FS.readFile leaseFile
      let now ← IO.monoMsNow
      pure (text.toNat?.map (fun t => decide (now - t < 5000)) |>.getD false)
    catch _ => pure false
    unless healthy do
      let _ ← System.Process.run "sh" #["-c", "kill -s KILL -- \"-$PPID\""] 1000
      IO.Process.exit 0

/-- Multiple compact JSON frames on stdin/stdout. A response has its own status
    and bounded request-local log; stderr is not a shared log transport. -/
def workerMain (functions : List FunctionImpl) (graphs : List (String × Except String GraphImpl))
    (leaseFile : String) : IO UInt32 := do
  let _ ← IO.asTask (prio := .dedicated) (superviseParent leaseFile)
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  repeat
    let text ← stdin.getLine
    if text.isEmpty then break
    unless text.utf8ByteSize ≤ 64 * 1024 * 1024 + 1 do
      throw (IO.userError "worker request exceeds 64 MiB")
    let log ← IO.mkRef emptyTrace
    let id := ((Json.parse text).toOption.bind fun j => (j.getObjValAs? Nat "id").toOption).getD 0
    let result ← try
      match Json.parse text >>= fun j => do
        let j ← j.getObjVal? "call"
        return (← j.getObjValAs? String "kind", ← j.getObjValAs? String "name", ← j.getObjVal? "request") with
      | .error e => pure (.error e)
      | .ok (kind, name, req) => runCommand functions graphs kind name req (some log)
    catch e => pure (.error (toString e))
    let (status, body) := match result with
      | .ok j => (200, j)
      | .error e => (400, Json.mkObj [("error", Json.str e)])
    let trace := (← log.get).value.trimAscii.toString
    let body := if trace.isEmpty then body else body.setObjVal! "log" (Json.str trace)
    stdout.putStrLn (Json.mkObj [("id", toJson id), ("status", toJson status), ("body", body)]).compress
    stdout.flush
  return 0

/-- The driver's protocol. One JSON request on stdin, one JSON response on
    stdout; functions' traces go to stderr.

    - `describe` — the functions and graphs (no stdin).
    - `function NAME` — a function request (`runFunction`).
    - `graph NAME` — a graph request (`runGraph`), stateless.
    State and producer scheduling travel in graph requests and responses.

    Exit code `0` for a response (which may report per-call errors), `1` for a
    request that could not be served (`{"error": …}` on stdout), `2` for a bad
    command line. -/
def driverMain (functions : List FunctionImpl) (graphs : List (String × Except String GraphImpl))
    (args : List String) :
    IO UInt32 := do
  let respond (r : Except String Json) : IO UInt32 := do
    match r with
    | .ok j => IO.println j.compress; pure 0
    | .error e => IO.println (Json.mkObj [("error", e)]).compress; pure 1
  let request : IO (Except String Json) := do
    let text ← (← IO.getStdin).readToEnd
    pure (if text.trimAscii.isEmpty then .ok (Json.mkObj []) else Json.parse text)
  match args with
  | ["worker", leaseFile] => workerMain functions graphs leaseFile
  | ["describe"] =>
    match graphs.findSome? fun (name, d) => (GraphImpl.error? d).map (name, ·) with
    | some (name, e) => respond (.error s!"graph '{name}': {e}")
    | none => respond (.ok (describe functions (graphs.filterMap fun (n, d) => d.toOption.map (n, ·))))
  | ["function", name] =>
    match functions.find? (·.name == name) with
    | none => respond (.error s!"no function named '{name}'")
    | some c => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runFunction c req)
  | ["graph", name] =>
    match graphs.lookup name with
    | none => respond (.error s!"no graph named '{name}'")
    | some (.error e) => respond (.error s!"graph '{name}': {e}")
    | some (.ok d) => match ← request with
      | .error e => respond (.error s!"request is not JSON: {e}")
      | .ok req => respond (← runGraph d (req.setObjVal! "_graph" (toJson name)))
  | _ =>
    IO.eprintln "usage: lun-driver (describe | function NAME | graph NAME)"
    pure 2

end LunDriver
