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

end LunTests.Session
