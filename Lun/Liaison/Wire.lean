/-
  Lun.Liaison.Wire — liaison's `POST /v0/egress`, as lun speaks it

  lun never holds a repository credential. A build request that needs one
  carries what the typednotes app hands out for a connection: a **warrant**
  minted for that connection (`typednotes/typednotes`'s `docs/connections.md`
  §7) and the connection's **account** (`{user_id}/{connection_id}`). lun
  forwards the warrant to liaison with each call; liaison verifies it, fetches
  the credential from the vault, makes the call and relays the answer.

  The request fields next to the warrant (`provider`, `action`, `resource`,
  `runId`, `orgId`) are not taken from the build request but derived from the
  warrant's own caveats (`Grant.ofWarrant`), so they cannot disagree with it:
  liaison re-checks them against the warrant anyway, and a mismatch would only
  turn into a denial. The wire format is liaison's
  (`liaison/Liaison/Server.lean`); numbers travel as decimal strings.
-/
import Lean.Data.Json
import Linen.Data.Hex

namespace Lun.Liaison

open Lean (Json)

-- ── What a warrant grants ───────────────────────────────────────────────────

/-- The request fields a warrant determines. -/
structure Grant where
  orgId : String
  runId : String
  provider : String
  action : String
  resource : String
  deriving DecidableEq, Repr

private def str (j : Json) (field : String) : Except String String :=
  match j.getObjValAs? String field with
  | .ok s => .ok s
  | .error _ => .error s!"warrant: \"{field}\" must be a string"

/-- Read the grant off a warrant's caveats. Caveats travel most recent first;
    every one must hold, so the first of each kind is as good as any — liaison
    refuses the call if two of them disagree. -/
def Grant.ofWarrant (w : Json) : Except String Grant := do
  let orgId ← str w "orgId"
  let caveats ← match w.getObjValAs? (Array Json) "caveats" with
    | .ok cs => pure cs.toList
    | .error _ => throw "warrant: \"caveats\" must be an array"
  let ofKind (k : String) := caveats.find? fun c => (c.getObjValAs? String "kind").toOption == some k
  let some cap := ofKind "capability" | throw "warrant: no capability caveat"
  let some res := ofKind "resource" | throw "warrant: no resource caveat"
  let some run := ofKind "runId" | throw "warrant: no runId caveat"
  return { orgId, runId := ← str run "value", provider := ← str cap "provider"
           action := ← str cap "action", resource := ← str res "value" }

/-- A connection account, `{user_id}/{connection_id}`: two segments of
    `[A-Za-z0-9_-]`, the second being the warrant's resource. -/
def validAccount (account : String) (g : Grant) : Bool :=
  match account.splitOn "/" with
  | [a, b] =>
    let ok (s : String) := !s.isEmpty && s.all fun c => c.isAlphanum || c == '_' || c == '-'
    ok a && ok b && b == g.resource
  | _ => false

-- ── The request ─────────────────────────────────────────────────────────────

/-- The body of one `POST /v0/egress` for a `GET` of `url`. `cost` is `0`:
    fetching a repository spends no credits (the app's warrants carry
    `budget(0)`). -/
def egressBody (warrant : Json) (g : Grant) (account : String) (now : Nat) (url : String)
    (headers : List (String × String) := []) : Json :=
  Json.mkObj
    [ ("warrant", warrant)
    , ("now", toString now), ("cost", "0")
    , ("provider", g.provider), ("action", g.action), ("resource", g.resource)
    , ("runId", g.runId), ("orgId", g.orgId)
    , ("call", Json.mkObj
        [ ("kind", "provider"), ("account", account), ("method", "GET"), ("url", url)
        , ("headers", Json.mkObj (headers.map fun (k, v) => (k, Json.str v))) ]) ]

-- ── The response ────────────────────────────────────────────────────────────

/-- What the provider answered, as liaison relays it. -/
structure Upstream where
  status : Nat
  headers : List (String × String)
  body : ByteArray

/-- A header's value, by case-insensitive name. -/
def Upstream.header? (u : Upstream) (name : String) : Option String :=
  (u.headers.find? fun (k, _) => k.toLower == name.toLower).map Prod.snd

/-- Read liaison's answer: `200` with `{"status", "headers", "body": <hex>}`
    relays the provider; anything else is liaison's own refusal,
    `{"error": code}`. -/
def parseResponse (httpStatus : Nat) (body : String) : Except String Upstream := do
  let j ← Json.parse body |>.mapError (s!"liaison answered with non-JSON ({httpStatus}): " ++ ·)
  if httpStatus != 200 then
    let code := (j.getObjValAs? String "error").toOption.getD "unknown"
    throw s!"liaison refused the call ({httpStatus} {code})"
  let status ← (j.getObjValAs? Nat "status").mapError (fun _ => "liaison: no upstream status")
  let headers ← match j.getObjVal? "headers" with
    | .ok (.obj kvs) => kvs.toList.mapM fun (k, v) => match v with
      | .str s => pure (k, s)
      | _ => throw "liaison: a header value is not a string"
    | _ => pure []
  let hex ← (j.getObjValAs? String "body").mapError (fun _ => "liaison: no upstream body")
  let some bytes := Data.Hex.decode hex | throw "liaison: the upstream body is not hex"
  return { status, headers, body := bytes }

end Lun.Liaison
