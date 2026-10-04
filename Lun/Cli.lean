/- Lun.Cli — newline-delimited JSON requests/replies on stdin/stdout. -/
import Lun.Api

namespace Lun.Cli

open Lean (Json toJson)

/-- One REST-shaped command. Builds wait by default in the stream transport. -/
structure Request where
  method : String
  path : List String
  body : String
  waitBuild : Bool

/-- Validate the complete command before any operation runs. -/
def Request.parse (text : String) : Except String Request := do
  unless text.toUTF8.size ≤ Api.maxBodyBytes do throw "the command is too large"
  let json ← parseRequestJson text
  let .obj _ := json | throw "the command must be a JSON object"
  let method ← json.getObjValAs? String "method"
  unless ["GET", "POST", "DELETE"].contains method do throw "method must be GET, POST or DELETE"
  let path ← json.getObjValAs? String "path"
  unless path.startsWith "/" && !path.contains '?' && !path.contains '#' do
    throw "path must be an absolute API path without a query or fragment"
  let body ← match json.getObjVal? "body" with
    | .error _ => pure ""
    | .ok (.obj values) => pure (Json.obj values).compress
    | .ok _ => throw "body must be a JSON object"
  let waitBuild ← match json.getObjVal? "wait" with
    | .error _ => pure true
    | .ok (.bool value) => pure value
    | .ok _ => throw "wait must be a boolean"
  return { method, path := (path.splitOn "/").drop 1, body, waitBuild }

/-- Each input line receives exactly one JSON reply. Malformed commands do not
    stop the stream. Diagnostics use stderr; stdout is exclusively protocol.
    EOF waits for submitted background builds before the process exits. -/
def run (b : Builder) : IO UInt32 := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  let mut exitCode := 0
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    if line.trimAscii.isEmpty then continue
    let response ← match Request.parse line with
      | .error e => pure (Api.error 400 e)
      | .ok request =>
        try Api.dispatch b request.method request.path request.body request.waitBuild
        catch e => pure (Api.error 500 (toString e))
    if response.status ≥ 400 then
      exitCode := 1
      IO.eprintln s!"lun: request failed ({response.status}): {response.body.compress}"
    output.putStrLn (Json.mkObj [("status", toJson response.status), ("body", response.body)]).compress
    output.flush
  repeat
    if (← b.running.get).isEmpty then break
    IO.sleep 50
  return exitCode

end Lun.Cli
