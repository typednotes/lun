/-
  Tests for `Lun.Session`'s pure parts: a stored session round-trips, and its
  public view carries everything but the driver's state.
-/
import Lun.Session

open Lean (Json toJson)
open Lun

namespace LunTests.Session

def record : SessionRecord :=
  { build := "".pushn 'b' 64, graph := "invoice", state := Json.mkObj [("now", 3)]
    nodes := Json.arr #[Json.mkObj [("id", 0), ("input", "x"), ("output", 5)]], updates := 2 }

#guard match SessionRecord.ofJson (toJson record) with
  | .ok r => r.build == record.build && r.graph == "invoice" && r.state == record.state &&
      r.nodes == record.nodes && r.updates == 2
  | .error _ => false
#guard (SessionRecord.ofJson (Json.mkObj [("build", "x")])).toOption.isNone

-- The view hides the state: it is lun's to keep, not the client's to forge.
#guard ((record.view ("".pushn 's' 64)).getObjVal? "state").toOption.isNone
#guard ((record.view ("".pushn 's' 64)).getObjValAs? Nat "updates").toOption == some 2

#guard validSessionId ("".pushn 'a' 64)
#guard !validSessionId "../../etc/passwd"

def execution (effects domains : List String) : Json := Json.mkObj
  [("binding", Json.mkObj [("org_id", "o"), ("user_id", "u")]),
   ("policy", Json.mkObj [("effects", toJson effects), ("domains", toJson domains)])]

#guard executionNarrows (execution ["HTTP"] ["example.org"]) (execution ["HTTP", "Trace"] ["example.org", "other.org"])
#guard !executionNarrows (execution ["HTTP", "Trace"] []) (execution ["HTTP"] [])
#guard !executionNarrows (execution ["HTTP"] ["other.org"]) (execution ["HTTP"] ["example.org"])
#guard !executionNarrows ((execution [] []).setObjVal! "binding" (Json.mkObj [("org_id", "other"), ("user_id", "u")])) (execution [] [])
#guard (ExecutionRefresh.check? (execution ["Trace"] []) (Json.mkObj [])).isSome
#guard (ExecutionRefresh.check? (execution [] []) (execution ["Trace"] [])).isNone

def secretExecution : Json := (execution [] []).mergeObj (Json.mkObj
  [("_runtime", Json.mkObj [("SECRETS_PASSWORD", "must-not-persist")]),
   ("secrets", "must-not-persist"), ("warrants", "must-not-persist"),
   ("connectors", Json.mkObj [("cell", Json.arr #[Json.mkObj [("provider", "s3"),
     ("warrants", Json.arr #["must-not-persist"]), ("token", "must-not-persist")]])])])
#guard ((publicExecution secretExecution).compress.splitOn "must-not-persist").length == 1

open Control.Monad.Effect.Connector in
def cap : Capability := { provider := "s3", connection := "c", scopes := [{ operation := "objects.read", root := ["reports"] }] }
def grant : Json := Json.mkObj [("provider", "s3"), ("connection", "c"), ("account", "u/c"),
  ("organization", toJson cap), ("connectionPermissions", toJson cap), ("cell", toJson cap), ("warrantPermissions", toJson cap)]
def granted : Json := (execution ["Connector"] []).setObjVal! "connectors" (Json.mkObj [("cell", Json.arr #[grant])])
#guard executionNarrows granted granted
-- The current app publishes cell + operation warrants, without a separate
-- envelope warrantPermissions field. It must still narrow on refresh.
def appGrant : Json := Json.mkObj [("provider", "s3"), ("connection", "c"), ("account", "u/c"),
  ("organization", toJson cap), ("connectionPermissions", toJson cap), ("cell", toJson cap)]
def appGranted : Json := (execution ["Connector"] []).setObjVal! "connectors" (Json.mkObj [("cell", Json.arr #[appGrant])])
#guard executionNarrows appGranted appGranted
#guard executionNarrows granted appGranted
#guard !executionNarrows (appGranted.setObjVal! "connectors" (Json.mkObj [("cell", Json.arr #[appGrant.setObjVal! "cell" (toJson { cap with maxResponseBytes := cap.maxResponseBytes + 1 })])])) appGranted
#guard !executionNarrows (appGranted.setObjVal! "connectors" (Json.mkObj [("cell", Json.arr #[appGrant.setObjVal! "warrantPermissions" Json.null])])) appGranted
#guard !executionNarrows ((execution ["Connector"] []).setObjVal! "connectors" (Json.mkObj [("other-cell", Json.arr #[grant])] )) granted
#guard !executionNarrows ((execution ["Connector"] []).setObjVal! "connectors" (Json.mkObj [("cell", Json.arr #[grant.setObjVal! "warrantPermissions" (toJson { cap with maxResponseBytes := cap.maxResponseBytes + 1 })])] )) granted
#guard !executionNarrows ((execution ["Connector"] []).setObjVal! "connectors" (Json.mkObj [("cell", Json.arr #[grant.setObjVal! "cell" (Json.mkObj [])])] )) granted
#guard (parseRequestJson "{\"binding\":{},\"binding\":{\"org_id\":\"other\"}}").toOption.isNone

end LunTests.Session
