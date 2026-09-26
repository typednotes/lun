/-
  Tests for `Lun.Build`'s pure parts: ids, states, statuses round-tripping
  through JSON, and how diagnostics are reported.
-/
import Lun.Build

open Lean (Json toJson)
open Lun

namespace LunTests.Build

#guard validId ("".pushn 'a' 64)
#guard !validId ("".pushn 'a' 63)
#guard !validId ("../" ++ "".pushn 'a' 61)

#guard [State.queued, .fetching, .building, .ready, .failed].all fun s => State.ofString? s.toString == some s
#guard State.running .building && !State.running .ready && !State.running .failed

def status : Status :=
  { id := "".pushn 'a' 64, state := .ready, source := Json.mkObj [("commit", "x")]
    diagnostics := #[Json.mkObj [("scope", "cell")]]
    description := some (Json.mkObj [("cells", Json.arr #[Json.mkObj [("name", "c")]]), ("dags", Json.arr #[])]) }

#guard match Status.ofJson (toJson status) with
  | .ok s => s.id == status.id && s.state == .ready && s.diagnostics.size == 1 &&
      s.description.isSome && s.error.isNone
  | .error _ => false
#guard match Status.ofJson (toJson { status with state := .failed, error := some "boom", description := none }) with
  | .ok s => s.state == .failed && s.error == some "boom" && s.description.isNone
  | .error _ => false

-- Errors are always reported; warnings only about cells and DAGs.
def diag (sev : String) (file : String) : Diagnostics.Diagnostic :=
  { severity := sev, file := some file, line := some 1, column := some 0, message := "m" }
#guard reportable (diag "error" "Fixture/X.lean")
#guard !reportable (diag "warning" "Fixture/X.lean")
#guard reportable (diag "warning" "LunDriver/Cells/C0.lean")

end LunTests.Build
