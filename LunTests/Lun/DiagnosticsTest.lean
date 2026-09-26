/-
  Tests for `Lun.Diagnostics`, on output in the shape `lake build` prints.
-/
import Lun.Diagnostics

open Lun.Diagnostics

namespace LunTests.Diagnostics

def log : String := "✔ [44/47] Built Fixture.Math (1.1s)
✖ [45/47] Building LunDriver.Cells.C5 (2.2s)
trace: .> LEAN_PATH=… lean LunDriver/Cells/C5.lean
error: LunDriver/Cells/C5.lean:4:23: Type mismatch
  Fixture.double
has type
  Nat → Eff [] Nat
✖ [46/47] Building LunDriver.Dags.D1 (2.2s)
error: LunDriver/Dags/D1.lean:6:14: Application type mismatch
warning: Fixture/Rejected.lean:24:4: declaration uses `sorry`
error: ./LunDriver/Runtime.lean:1:0: unknown module prefix 'Linen.Control.Reactive'
Some required targets logged failures:
- LunDriver.Cells.C5
error: build failed"

def ds : List Diagnostic := parse log

#guard ds.length == 5
#guard ds[0]!.file == some "LunDriver/Cells/C5.lean" && ds[0]!.line == some 4 && ds[0]!.column == some 23
-- Continuation lines belong to the message; the next header ends it.
#guard ds[0]!.message == "Type mismatch\n  Fixture.double\nhas type\n  Nat → Eff [] Nat"
#guard ds[0]!.scope == .cell 5
#guard ds[1]!.scope == .dag 1
#guard ds[2]!.severity == "warning" && ds[2]!.scope == .project
#guard ds[3]!.scope == .driver
#guard ds[4]!.scope == .build && ds[4]!.file == none && ds[4]!.message == "build failed"

-- A DAG position becomes a position in the program.
#guard (ds[1]!.inProgram (3, 22)).line == some 4
#guard ({ ds[1]! with line := some 3, column := some 30 }.inProgram (3, 22)).column == some 8
#guard ({ ds[1]! with line := some 2 }.inProgram (3, 22)).line == none

#guard (linenTooOldHint ds[3]!).isSome
#guard (linenTooOldHint ds[0]!).isNone

#guard splitLocation "a.lean:1:2: x: y" == (some "a.lean", some 1, some 2, "x: y")
#guard splitLocation "build failed" == (none, none, none, "build failed")

end LunTests.Diagnostics
