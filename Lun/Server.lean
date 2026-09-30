/-
  Lun.Server — lun's HTTP API

  | Route | |
  |---|---|
  | `GET /_health` | `200 ok` (liveness) |
  | `POST /v0/builds` | submit a build request (`Lun.Spec`); `202` with its status while it runs, `200` if that build is already ready |
  | `GET /v0/builds/{id}` | the build's status: state, diagnostics, and once ready its functions and graphs |
  | `GET /v0/builds/{id}/log` | the build's log (`text/plain`) |
  | `POST /v0/builds/{id}/functions/{name}` | the function's service: `{"input": x}` → `{"output": y}`, `{"inputs": [x, …]}` → `{"outputs": [...]}` |
  | `POST /v0/builds/{id}/graphs/{name}` | the graph's service: `{"inputs": {"name": x, …}}` → `{"nodes": [...]}`, every node's value |
  | `POST /v0/builds/{id}/graphs/{name}/sessions` | start a session of the graph (`Lun.Session`): `201` `{"session", "nodes"}` |
  | `GET /v0/sessions/{session}` | the session's nodes |
  | `POST /v0/sessions/{session}` | update some inputs: `{"inputs": {…}}` → `{"changed": [...], "nodes": [...]}` |
  | `DELETE /v0/sessions/{session}` | end the session |

  Errors are `{"error": message}`. When `LUN_TOKEN` is set every route but
  `/_health` requires `Authorization: Bearer {token}`.
-/
import Lean.Data.Json
import Linen.Network.WebApp
import Linen.Crypto.ConstantTime
import Lun.Session

namespace Lun

open Lean (Json toJson)
open Network.HTTP.Types

/-- The largest request body accepted: build requests and function calls alike. -/
def maxBodyBytes : Nat := 16 * 1024 * 1024

/-- The statuses lun answers with. -/
def statusOf : Nat → Network.HTTP.Types.Status
  | 200 => status200 | 201 => status201 | 202 => status202 | 400 => status400 | 401 => status401
  | 403 => status403 | 404 => status404 | 409 => status409 | 502 => status502 | 504 => status504
  | _ => status500

private def json (code : Nat) (body : Json) : Network.WebApp.Response :=
  Network.WebApp.responseLBS (statusOf code) [(hContentType, "application/json")] body.compress

private def error (code : Nat) (msg : String) : Network.WebApp.Response :=
  json code (Json.mkObj [("error", toJson msg)])

/-- Read the body, refusing more than `maxBodyBytes`. -/
private def readBody (req : Network.WebApp.Request) : IO (Option String) := do
  let mut acc := ByteArray.empty
  repeat
    let chunk ← Network.WebApp.getRequestBodyChunk req
    if chunk.isEmpty then break
    acc := acc ++ chunk
    if acc.size > maxBodyBytes then return none
  return String.fromUTF8? acc

/-- The request carries the configured token, if one is configured. -/
def authorized (cfg : Config) (req : Network.WebApp.Request) : Bool :=
  match cfg.token with
  | none => true
  | some token =>
    let header := (req.requestHeaders.find? (·.1 == Data.CI.mk' "Authorization")).map (·.2)
    match header with
    | some h => Crypto.ConstantTime.eqString h s!"Bearer {token}"
    | none => false

private def submit (b : Builder) (req : Network.WebApp.Request) : IO Network.WebApp.Response := do
  let some text ← readBody req | return error 400 "the request body is too large or not UTF-8"
  let j ← match parseRequestJson text with
    | .ok j => pure j
    | .error e => return error 400 s!"the request is not JSON: {e}"
  match BuildSpec.parse j b.cfg.allowLocal with
  | .error e => return error 400 e
  | .ok spec =>
    let s ← b.submit spec
    return json (if s.state == .ready then 200 else 202) (toJson s)

/-- Answer with what an operation answered, reading the body first. -/
private def withBody (req : Network.WebApp.Request) (op : String → IO Answer) :
    IO Network.WebApp.Response := do
  let some text ← readBody req | return error 400 "the request body is too large or not UTF-8"
  let a ← op text
  return json a.status a.body

private def call (b : Builder) (id kind name : String) (req : Network.WebApp.Request) :
    IO Network.WebApp.Response := do
  let some text ← readBody req | return error 400 "the request body is too large or not UTF-8"
  let a ← b.call id kind name text
  return json a.status a.body

/-- Route one request. -/
def route (b : Builder) (ss : Sessions) (req : Network.WebApp.Request) :
    IO Network.WebApp.Response := do
  let m := req.requestMethod
  let get := m == .standard .GET
  let post := m == .standard .POST
  let delete := m == .standard .DELETE
  match req.pathInfo with
  | ["_health"] =>
    if get then return Network.WebApp.responseLBS status200 [(hContentType, "text/plain")] "ok"
    else return error 404 "not found"
  | path =>
    unless authorized b.cfg req do return error 401 "missing or wrong bearer token"
    match path with
    | ["v0", "builds"] =>
      if post then submit b req else return error 404 "not found"
    | ["v0", "builds", id] =>
      unless get && validId id do return error 404 "not found"
      match ← readStatus b.cfg id with
      | some s => return json 200 (toJson s)
      | none => return error 404 "no such build"
    | ["v0", "builds", id, "log"] =>
      unless get && validId id do return error 404 "not found"
      let file := logFile b.cfg id
      unless ← file.pathExists do return error 404 "no log for this build"
      return Network.WebApp.responseLBS status200 [(hContentType, "text/plain; charset=utf-8")]
        (← IO.FS.readFile file)
    | ["v0", "builds", id, "functions", name] =>
      unless post && validId id && Validate.functionName name do return error 404 "not found"
      call b id "function" name req
    | ["v0", "builds", id, "graphs", name] =>
      unless post && validId id && Validate.functionName name do return error 404 "not found"
      call b id "graph" name req
    | ["v0", "builds", id, "graphs", name, "sessions"] =>
      unless post && validId id && Validate.functionName name do return error 404 "not found"
      withBody req (b.startSession id name)
    | ["v0", "sessions", session] =>
      unless validSessionId session do return error 404 "not found"
      if get then
        let a ← b.readSession session
        return json a.status a.body
      else if post then withBody req (b.updateSession ss session)
      else if delete then
        let a ← b.endSession ss session
        return json a.status a.body
      else return error 404 "not found"
    | _ => return error 404 "not found"

/-- lun's `Application`. An unexpected exception is a `500`, never a dropped
    connection. -/
def application (b : Builder) (ss : Sessions) : Network.WebApp.Application :=
  fun req respond =>
    Network.WebApp.AppM.respondIO respond do
      try route b ss req
      catch e => pure (error 500 (toString e))

end Lun
