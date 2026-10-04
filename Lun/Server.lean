/-
  Lun.Server — lun's HTTP API

  | Route | |
  |---|---|
  | `GET /_health` | `200 ok` (liveness) |
  | `POST /v0/builds` | submit a build request (`Lun.Spec`); `202` with its status while it runs, `200` if that build is already ready |
  | `GET /v0/builds/{id}` | the build's status: state, diagnostics, and once ready its functions and graphs |
  | `GET /v0/builds/{id}/log` | the build's log (`text/plain`) |
  | `POST /v0/builds/{id}/functions/{name}` | the function's service: `{"input": x}` → `{"output": y}`, `{"inputs": [x, …]}` → `{"outputs": [...]}` |
  | `POST /v0/builds/{id}/graphs/{name}` | stateless graph step: `{"state": …, "inputs": {…}}` → `{"state", "nodes", "changed", "nextCallAt"}` |

  Errors are `{"error": message}`. When `LUN_TOKEN` is set every route but
  `/_health` requires `Authorization: Bearer {token}`.
-/
import Lean.Data.Json
import Linen.Network.WebApp
import Linen.Crypto.ConstantTime
import Lun.Api

namespace Lun

open Lean (Json toJson)
open Network.HTTP.Types

/-- The largest request body accepted: build requests and function calls alike. -/
def maxBodyBytes : Nat := Api.maxBodyBytes

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

/-- Route one request. -/
def route (b : Builder) (req : Network.WebApp.Request) :
    IO Network.WebApp.Response := do
  unless req.pathInfo == ["_health"] || authorized b.cfg req do
    return error 401 "missing or wrong bearer token"
  let body ← if req.requestMethod == .standard .POST then do
    let some text ← readBody req | return error 400 "the request body is too large or not UTF-8"
    pure text
    else pure ""
  let response ← Api.dispatch b (toString req.requestMethod) req.pathInfo body
  if response.text then
    return Network.WebApp.responseLBS (statusOf response.status)
      [(hContentType, "text/plain; charset=utf-8")] (response.body.getStr?.toOption.getD "")
  return json response.status response.body

/-- lun's `Application`. An unexpected exception is a `500`, never a dropped
    connection. -/
def application (b : Builder) : Network.WebApp.Application :=
  fun req respond =>
    Network.WebApp.AppM.respondIO respond do
       try route b req
      catch e => pure (error 500 (toString e))

end Lun
