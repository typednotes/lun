/-
  Tests for `Lun.Diagnostics`, on output in the shape `lake build` prints.
-/
import Lun.Diagnostics

open Lun.Diagnostics

namespace LunTests.Diagnostics

def log : String := "✔ [44/47] Built Fixture.Math (1.1s)
✖ [45/47] Building LunDriver.Functions.F5 (2.2s)
trace: .> LEAN_PATH=… lean LunDriver/Functions/F5.lean
error: LunDriver/Functions/F5.lean:4:23: Type mismatch
  Fixture.double
has type
  Nat → Eff [] Nat
✖ [46/47] Building LunDriver.Graphs.G1 (2.2s)
error: LunDriver/Graphs/G1.lean:6:14: Application type mismatch
warning: Fixture/Rejected.lean:24:4: declaration uses `sorry`
error: ./LunDriver/Runtime.lean:1:0: unknown module prefix 'Linen.Control.Reactive'
Some required targets logged failures:
- LunDriver.Functions.F5
error: build failed"

def ds : List Diagnostic := parse log

#guard ds.length == 5
#guard ds[0]!.file == some "LunDriver/Functions/F5.lean" && ds[0]!.line == some 4 && ds[0]!.column == some 23
-- Continuation lines belong to the message; the next header ends it.
#guard ds[0]!.message == "Type mismatch\n  Fixture.double\nhas type\n  Nat → Eff [] Nat"
#guard scope ds[0]! == .function 5
#guard scope ds[1]! == .graph 1
#guard ds[2]!.severity == "warning" && scope ds[2]! == .project
#guard scope ds[3]! == .driver
#guard scope ds[4]! == .build && ds[4]!.file == none && ds[4]!.message == "build failed"

-- A graph position becomes a position in the program.
#guard (inProgram ds[1]! (3, 22)).line == some 4
#guard (inProgram { ds[1]! with line := some 3, column := some 30 } (3, 22)).column == some 8
#guard (inProgram { ds[1]! with line := some 2 } (3, 22)).line == none

#guard (linenTooOldHint ds[3]!).isSome
#guard (linenTooOldHint ds[0]!).isNone

-- (Parsing itself is linen's `System.LakeLog`, tested there.)

end LunTests.Diagnostics
