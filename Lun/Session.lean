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

instance : Lean.ToJson SessionRecord where
  toJson r := Json.mkObj
    [ ("build", toJson r.build), ("graph", toJson r.graph), ("state", r.state), ("nodes", r.nodes)
    , ("updates", toJson r.updates) ]

/-- Read a stored session back. -/
def SessionRecord.ofJson (j : Json) : Except String SessionRecord := do
  return { build := ← j.getObjValAs? String "build", graph := ← j.getObjValAs? String "graph"
           state := ← j.getObjVal? "state", nodes := ← j.getObjVal? "nodes"
           updates := ← j.getObjValAs? Nat "updates" }

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
  else (Json.parse text).mapError fun e => errorAnswer 400 s!"the request is not JSON: {e}"

/-- A driver answer's field, or a `502`. -/
private def field (a : Answer) (k : String) : Except Answer Json :=
  (a.body.getObjVal? k).mapError fun _ => errorAnswer 502 s!"the driver's answer has no \"{k}\""

/-- Start a session of graph `graph` of build `build`: `{"inputs": {…}}`. -/
def Builder.startSession (b : Builder) (build graph body : String) : IO Answer := do
  let req ← match parseBody body with
    | .ok j => pure j
    | .error a => return a
  let a ← b.call build "session-start" graph
    (Json.mkObj [("inputs", (req.getObjVal? "inputs").toOption.getD (Json.mkObj []))]).compress
  unless a.status == 200 do return a
  match field a "state", field a "nodes" with
  | .error e, _ | _, .error e => return e
  | .ok state, .ok nodes =>
    let session := Data.Hex.encode (← Crypto.SecureRandom.randomBytes 32)
    writeSession b.cfg session { build, graph, state, nodes, updates := 0 }
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
    let a ← b.call r.build "session-update" r.graph
      (Json.mkObj [ ("state", r.state)
                  , ("inputs", (req.getObjVal? "inputs").toOption.getD (Json.mkObj [])) ]).compress
    unless a.status == 200 do return a
    match field a "state", field a "nodes", field a "changed" with
    | .error e, _, _ | _, .error e, _ | _, _, .error e => return e
    | .ok state, .ok nodes, .ok changed =>
      let r := { r with state, nodes, updates := r.updates + 1 }
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
