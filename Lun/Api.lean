/- Lun.Api — the operations shared by the HTTP and standard-stream transports. -/
import Lun.Build

namespace Lun.Api

open Lean (Json toJson)

/-- The largest body accepted by either transport. -/
def maxBodyBytes : Nat := 16 * 1024 * 1024

/-- A response body is JSON, or a JSON string for a plain-text route. -/
structure Response where
  status : Nat
  body : Json
  text : Bool := false

/-- Transport-independent API error. -/
def error (code : Nat) (message : String) : Response :=
  { status := code, body := Json.mkObj [("error", toJson message)] }

private def answer (operation : IO Answer) : IO Response := do
  let result ← operation
  return { status := result.status, body := result.body }

/-- Route a validated transport request. HTTP builds are asynchronous; the
    CLI can wait for completion while sharing all validation and execution. -/
def dispatch (b : Builder) (method : String) (path : List String)
    (body : String := "") (waitBuild : Bool := false) : IO Response := do
  if body.toUTF8.size > maxBodyBytes then return error 400 "the request body is too large"
  let get := method == "GET"
  let post := method == "POST"
  match path with
  | ["_health"] =>
    if get then return { status := 200, body := "ok", text := true }
    else return error 404 "not found"
  | ["v0", "builds"] =>
    unless post do return error 404 "not found"
    let json ← match parseRequestJson body with
      | .ok j => pure j
      | .error e => return error 400 s!"the request is not JSON: {e}"
    let spec ← match BuildSpec.parse json b.cfg.allowLocal with
      | .ok spec => pure spec
      | .error e => return error 400 e
    let status ← match ← (b.submit spec).toBaseIO with
      | .ok status => pure status
      | .error e =>
        if spec.source.directory.isSome then return error 400 (toString e)
        else throw e
    if waitBuild then
      let status ← b.wait status.id
      return { status := if status.state == .ready then 200 else 422, body := toJson status }
    return { status := if status.state == .ready then 200 else 202, body := toJson status }
  | ["v0", "builds", id] =>
    unless get && validId id do return error 404 "not found"
    match ← readStatus b.cfg id with
    | some status => return { status := 200, body := toJson status }
    | none => return error 404 "no such build"
  | ["v0", "builds", id, "log"] =>
    unless get && validId id do return error 404 "not found"
    let file := logFile b.cfg id
    unless ← file.pathExists do return error 404 "no log for this build"
    return { status := 200, body := toJson (← IO.FS.readFile file), text := true }
  | ["v0", "builds", id, "functions", name] =>
    unless post && validId id && Validate.functionName name do return error 404 "not found"
    answer (b.call id "function" name body)
  | ["v0", "builds", id, "graphs", name] =>
    unless post && validId id && Validate.functionName name do return error 404 "not found"
    answer (b.call id "graph" name body)
  | _ => return error 404 "not found"

end Lun.Api
