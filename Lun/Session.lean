/-
  Lun.Session — live graphs: register a graph, update some inputs, get back
  what changed

  A **session** is a graph of a ready build kept alive between calls: its inputs
  keep their values, and an update feeds only the inputs it names, so only the
  functions downstream of them run again. The answer lists the nodes whose outcome
  changed (a value, a function's error, or being skipped), with the new outcome.

  | Route | |
  |---|---|
  | `POST /v0/builds/{id}/graphs/{name}/sessions` | start one: `{"inputs": {…}}` (optional) → `{"session", "nodes"}` |
  | `GET /v0/sessions/{session}` | every node's current outcome |
  | `POST /v0/sessions/{session}` | update: `{"inputs": {"x": 5}}` → `{"changed": [...], "nodes": [...]}` |
  | `DELETE /v0/sessions/{session}` | end it |

  The session's state is linen's: its reactive graph's `Session` (the clock
  and every node's operator state) and every node's outcome, as JSON. The
  driver computes, lun stores: `{workdir}/sessions/{session}.json` holds the
  build, the graph and that state, rewritten atomically after each update, so
  sessions survive a restart. Updates of one session are serialised (a lock
  per session); different sessions update concurrently.

  Session ids are 32 random bytes, hex: knowing one is the capability to
  read, update and end it (besides `LUN_TOKEN`).
-/
import Lean.Data.Json
import Std.Sync.Mutex
import Linen.Crypto.SecureRandom
import Linen.Data.Hex
import Lun.Build
import Linen.Control.Monad.Effect.Connector

namespace Lun

open Lean (Json toJson)
open System (FilePath)

-- ── Storage ─────────────────────────────────────────────────────────────────

/-- A session id: 64 lowercase hex digits (the same shape as a build id). -/
def validSessionId (s : String) : Bool := validId s

/-- Where a session is stored. -/
def sessionFile (cfg : Config) (session : String) : FilePath :=
  cfg.workdir / "sessions" / s!"{session}.json"

/-- What is stored of a session. -/
structure SessionRecord where
  build : String
  graph : String
  /-- The driver's state (`LunDriver.SessionState`), opaque to lun. -/
  state : Json
  /-- Every node with its current outcome, as last reported. -/
  nodes : Json
  /-- How many updates it has had. -/
  updates : Nat
  /-- Authority and user binding; never accepted from a compiled graph's state. -/
  execution : Json := Json.mkObj []

/-- Persist only public ceilings and binding, never arbitrary request fields,
    private runtime data, credential values or operation warrants. -/
def publicExecution (execution : Json) : Json :=
  let connectors := (execution.getObjVal? "connectors").toOption.getD (Json.mkObj [])
  let sanitized := match connectors with
    | .obj functions => Json.mkObj (functions.toList.map fun (name, grants) =>
      let values := ((grants.getArr?).toOption.getD #[]).map fun grant =>
        Json.mkObj (["provider", "connection", "account", "bucket", "organization", "connectionPermissions", "cell", "warrantPermissions"].filterMap fun field =>
          (grant.getObjVal? field).toOption.map (field, ·))
      (name, Json.arr values))
    | _ => Json.mkObj []
  Json.mkObj ((["policy", "binding"].filterMap fun field =>
    (execution.getObjVal? field).toOption.map (field, ·)) ++ [("connectors", sanitized)])

instance : Lean.ToJson SessionRecord where
  toJson r :=
    let execution := publicExecution r.execution
    Json.mkObj
    [ ("build", toJson r.build), ("graph", toJson r.graph), ("state", r.state), ("nodes", r.nodes)
    , ("updates", toJson r.updates), ("execution", execution) ]

/-- Read a stored session back. -/
def SessionRecord.ofJson (j : Json) : Except String SessionRecord := do
  return { build := ← j.getObjValAs? String "build", graph := ← j.getObjValAs? String "graph"
           state := ← j.getObjVal? "state", nodes := ← j.getObjVal? "nodes"
           updates := ← j.getObjValAs? Nat "updates"
           execution := (j.getObjVal? "execution").toOption.getD (Json.mkObj []) }

/-- The public view of a session: everything but the driver's state. -/
def SessionRecord.view (r : SessionRecord) (session : String) : Json :=
  Json.mkObj
    [ ("session", toJson session), ("build", toJson r.build), ("graph", toJson r.graph)
    , ("updates", toJson r.updates), ("nodes", r.nodes) ]

/-- Write a session atomically (write, then rename). -/
def writeSession (cfg : Config) (session : String) (r : SessionRecord) : IO Unit := do
  let file := sessionFile cfg session
  IO.FS.createDirAll (cfg.workdir / "sessions")
  let tmp := file.withExtension "json.tmp"
  IO.FS.writeFile tmp (toJson r).compress
  IO.FS.rename tmp file

/-- A stored session, if there is one. -/
def readSession (cfg : Config) (session : String) : IO (Option SessionRecord) := do
  let file := sessionFile cfg session
  unless ← file.pathExists do return none
  return (Json.parse (← IO.FS.readFile file) >>= SessionRecord.ofJson).toOption

-- ── The session table ───────────────────────────────────────────────────────

/-- The locks of the sessions being updated, so that one session's updates are
    serialised. -/
structure Sessions where
  locks : Std.Mutex (List (String × Std.Mutex Unit))

def Sessions.new : IO Sessions := return { locks := ← Std.Mutex.new [] }

/-- Run `act` holding session `session`'s lock. -/
def Sessions.withLock (ss : Sessions) (session : String) (act : IO α) : IO α := do
  let lock ← ss.locks.atomically do
    let locks ← get
    match locks.lookup session with
    | some l => pure l
    | none =>
      let l ← Std.Mutex.new ()
      set ((session, l) :: locks)
      pure l
  lock.atomically (m := IO) (monadLift act : Std.AtomicT Unit IO α)

-- ── Operations ──────────────────────────────────────────────────────────────

private def errorAnswer (status : Nat) (msg : String) : Answer :=
  { status, body := Json.mkObj [("error", toJson msg)] }

/-- The request body as JSON, or a `400`. -/
private def parseBody (text : String) : Except Answer Json :=
  if text.trimAscii.isEmpty then .ok (Json.mkObj [])
  else (parseRequestJson text).mapError fun e => errorAnswer 400 s!"the request is not JSON: {e}"

/-- A driver answer's field, or a `502`. -/
private def field (a : Answer) (k : String) : Except Answer Json :=
  (a.body.getObjVal? k).mapError fun _ => errorAnswer 502 s!"the driver's answer has no \"{k}\""

open Control.Monad.Effect.Connector in
/-- Session ceilings are independently typed; fresh warrants are not persisted. -/
structure SessionGrant where
  provider : String
  connection : String
  account : String
  organization : Capability
  connectionPermissions : Capability
  cell : Capability
  warrantPermissions : Capability
  bucket : Option String := none

instance : Lean.FromJson SessionGrant where
  fromJson? j := do
    let provider ← j.getObjValAs? String "provider"
    let connection ← j.getObjValAs? String "connection"
    let account ← j.getObjValAs? String "account"
    let organization ← Control.Monad.Effect.Connector.Capability.parse (← j.getObjVal? "organization")
    let connectionPermissions ← Control.Monad.Effect.Connector.Capability.parse (← j.getObjVal? "connectionPermissions")
    let cell ← Control.Monad.Effect.Connector.Capability.parse (← j.getObjVal? "cell")
    let warrantPermissions ← match j.getObjVal? "warrantPermissions" with
      | .ok value => Control.Monad.Effect.Connector.Capability.parse value
      | .error _ => pure cell
    let bucket := (j.getObjValAs? String "bucket").toOption
    return { provider, connection, account, organization, connectionPermissions, cell, warrantPermissions, bucket }

def SessionGrant.narrows (child parent : SessionGrant) : Bool :=
  child.provider == parent.provider && child.connection == parent.connection && child.account == parent.account && child.bucket == parent.bucket &&
    child.organization.narrows parent.organization &&
    child.connectionPermissions.narrows parent.connectionPermissions && child.cell.narrows parent.cell && child.warrantPermissions.narrows parent.warrantPermissions

theorem SessionGrant.narrows_organization {child parent : SessionGrant} (h : child.narrows parent = true) :
    child.organization.Narrows parent.organization := by
  simp only [SessionGrant.narrows, Bool.and_eq_true] at h
  exact Control.Monad.Effect.Connector.Capability.narrows_sound h.1.1.1.2

theorem SessionGrant.narrows_connection {child parent : SessionGrant} (h : child.narrows parent = true) :
    child.connectionPermissions.Narrows parent.connectionPermissions := by
  simp only [SessionGrant.narrows, Bool.and_eq_true] at h
  exact Control.Monad.Effect.Connector.Capability.narrows_sound h.1.1.2

theorem SessionGrant.narrows_cell {child parent : SessionGrant} (h : child.narrows parent = true) :
    child.cell.Narrows parent.cell := by
  simp only [SessionGrant.narrows, Bool.and_eq_true] at h
  exact Control.Monad.Effect.Connector.Capability.narrows_sound h.1.2

theorem SessionGrant.narrows_warrant {child parent : SessionGrant} (h : child.narrows parent = true) :
    child.warrantPermissions.Narrows parent.warrantPermissions := by
  simp only [SessionGrant.narrows, Bool.and_eq_true] at h
  exact Control.Monad.Effect.Connector.Capability.narrows_sound h.2

def sessionGrants (j : Json) : Except String (List (String × SessionGrant)) := do
  let fields ← ((j.getObjVal? "connectors").toOption.getD (Json.mkObj [])).getObj?
  let nested ← fields.toList.mapM fun (name, values) => do
    let values : List SessionGrant ← Lean.fromJson? values
    if (values.map (·.connection)).eraseDups.length != values.length then throw "duplicate connection grant"
    return values.map (name, ·)
  return nested.flatten

/-- Check an update's ceilings against the stored ceilings. Missing fresh
    connector grants revoke them for this request, rather than reusing tokens. -/
def executionNarrows (child parent : Json) : Bool := Id.run do
  unless (child.getObjVal? "binding").toOption == (parent.getObjVal? "binding").toOption do return false
  for key in ["effects", "domains"] do
    let policy (j : Json) := (j.getObjVal? "policy").toOption.getD (Json.mkObj [])
    let old := ((policy parent).getObjValAs? (List String) key).toOption.getD []
    let some next := ((policy child).getObjValAs? (List String) key).toOption
      | if (child.getObjVal? "policy").toOption.isSome then return false else continue
    unless next.all old.contains do return false
  let .ok old := sessionGrants parent | return false
  let .ok next := sessionGrants child | return false
  return next.all fun (name, grant) => old.any fun (oldName, oldGrant) =>
    name == oldName && grant.narrows oldGrant

/-- Validated state transition consumed by the actual session-update call. -/
structure ExecutionRefresh (previous : Json) where
  execution : Json
  attenuated : executionNarrows execution previous = true

def ExecutionRefresh.check? (previous request : Json) : Option (ExecutionRefresh previous) :=
  let execution := Json.mkObj ((["policy", "binding"].filterMap fun name =>
    ((request.getObjVal? name).toOption.orElse fun _ => (previous.getObjVal? name).toOption).map (name, ·)) ++
    [("connectors", (request.getObjVal? "connectors").toOption.getD (Json.mkObj []))])
  if h : executionNarrows execution previous = true then some ⟨execution, h⟩ else none

/-- Start a session of graph `graph` of build `build`: `{"inputs": {…}}`. -/
def Builder.startSession (b : Builder) (build graph body : String) : IO Answer := do
  let req ← match parseBody body with
    | .ok j => pure j
    | .error a => return a
  let execution := Json.mkObj <| ["policy", "binding", "connectors"].filterMap fun name =>
    (req.getObjVal? name).toOption.map (name, ·)
  let a ← b.call build "session-start" graph
    ((execution.setObjVal! "inputs" ((req.getObjVal? "inputs").toOption.getD (Json.mkObj []))).setObjVal! "recoverInputs"
      (Json.bool ((req.getObjValAs? Bool "recoverInputs").toOption == some true))).compress
  unless a.status == 200 do return a
  match field a "state", field a "nodes" with
  | .error e, _ | _, .error e => return e
  | .ok state, .ok nodes =>
    let session := Data.Hex.encode (← Crypto.SecureRandom.randomBytes 32)
    writeSession b.cfg session { build, graph, state, nodes, updates := 0, execution }
    let view := (SessionRecord.view { build, graph, state, nodes, updates := 0 } session)
    return { status := 201, body := match a.body.getObjVal? "log" with
      | .ok log => view.setObjVal! "log" log
      | .error _ => view }

/-- A session's current nodes. -/
def Builder.readSession (b : Builder) (session : String) : IO Answer := do
  match ← Lun.readSession b.cfg session with
  | none => return errorAnswer 404 "no such session"
  | some r => return { status := 200, body := r.view session }

/-- Update a session: `{"inputs": {…}}` → the nodes whose outcome changed. -/
def Builder.updateSession (b : Builder) (ss : Sessions) (session body : String) : IO Answer := do
  let req ← match parseBody body with
    | .ok j => pure j
    | .error a => return a
  ss.withLock session do
    let some r ← Lun.readSession b.cfg session | return errorAnswer 404 "no such session"
    if let .ok binding := req.getObjVal? "binding" then
      unless (r.execution.getObjVal? "binding").toOption == some binding do
        return errorAnswer 403 "a session's organization/user binding cannot change"
    let some refresh := ExecutionRefresh.check? r.execution req
      | return errorAnswer 403 "a session update cannot widen its policy or connector ceilings"
    let execution := refresh.execution
    let a ← b.call r.build "session-update" r.graph
      (execution.mergeObj (Json.mkObj [ ("state", r.state)
                  , ("inputs", (req.getObjVal? "inputs").toOption.getD (Json.mkObj [])) ])).compress
    unless a.status == 200 do return a
    match field a "state", field a "nodes", field a "changed" with
    | .error e, _, _ | _, .error e, _ | _, _, .error e => return e
    | .ok state, .ok nodes, .ok changed =>
      let r := { r with state, nodes, execution, updates := r.updates + 1 }
      writeSession b.cfg session r
      let body := Json.mkObj
        [ ("session", toJson session), ("updates", toJson r.updates), ("changed", changed)
        , ("nodes", nodes) ]
      return { status := 200, body := match a.body.getObjVal? "log" with
        | .ok log => body.setObjVal! "log" log
        | .error _ => body }

/-- End a session. -/
def Builder.endSession (b : Builder) (ss : Sessions) (session : String) : IO Answer := do
  ss.withLock session do
    let file := sessionFile b.cfg session
    unless ← file.pathExists do return errorAnswer 404 "no such session"
    IO.FS.removeFile file
    return { status := 200, body := Json.mkObj [("session", toJson session), ("ended", true)] }

end Lun
