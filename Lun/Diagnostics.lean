/-
  Lun.Diagnostics — lake's output, as diagnostics about functions and graphs

  linen's `System.LakeLog` reads `lake build`'s messages (`error:
  FILE:LINE:COL: text`, possibly continuing on following lines); what is
  lun's is where they point. Because the driver has one module
  per function and per graph (`Lun.Driver`), the file alone says what a message is
  about: `LunDriver/Functions/F<i>.lean` is function `i`, `LunDriver/Graphs/G<j>.lean`
  is graph `j` (whose line numbers are translated back into the graph program),
  any other driver file is lun's own fault, and anything else is the
  project's.
-/
import Linen.System.LakeLog

namespace Lun.Diagnostics

/-- What a message is about. -/
inductive Scope where
  /-- The function at this index in the request. -/
  | function (index : Nat)
  /-- The graph at this index in the request. -/
  | graph (index : Nat)
  /-- The user project itself (its own modules failed to build). -/
  | project
  /-- lun's generated code — a lun bug, or a project whose linen is too old. -/
  | driver
  /-- No file: a failure of the build as a whole. -/
  | build
  deriving DecidableEq, Repr

/-- A diagnostic of lake's log, as linen's `System.LakeLog` parses it. The
    functions below take it as an argument (`scope d`), not by dot notation:
    `d.scope` would look in linen's `System.LakeLog.Diagnostic` namespace. -/
abbrev Diagnostic := System.LakeLog.Diagnostic

/-- The `error:` and `warning:` messages of a lake log, in order
    (`System.LakeLog.parse`). -/
def parse (log : String) : List Diagnostic := System.LakeLog.parse log

/-- `LunDriver/Functions/F12.lean` ↦ `12`, for `kind = "Functions"`, `letter = "F"`. -/
private def indexIn (file kind letter : String) : Option Nat :=
  let pfx := s!"LunDriver/{kind}/{letter}"
  let file := if file.startsWith "./" then (file.drop 2).toString else file
  if file.startsWith pfx && file.endsWith ".lean" then
    ((file.drop pfx.length).dropEnd 5).toString.toNat?
  else none

/-- What a diagnostic is about. -/
def scope (d : Diagnostic) : Scope :=
  match d.file with
  | none => .build
  | some f =>
    match indexIn f "Functions" "F", indexIn f "Graphs" "G" with
    | some i, _ => .function i
    | _, some j => .graph j
    | _, _ =>
      let f := if f.startsWith "./" then (f.drop 2).toString else f
      if f.startsWith "LunDriver/" then .driver else .project

/-- Translate a graph module position to a position in the graph program, given
    where the program starts (`Lun.Driver.graphProgramStart`). -/
def inProgram (d : Diagnostic) (start : Nat × Nat) : Diagnostic :=
  match d.line, d.column with
  | some l, some c =>
    if l < start.1 then { d with line := none, column := none }
    else if l == start.1 then { d with line := some 1, column := some (c - start.2) }
    else { d with line := some (l - start.1 + 1) }
  | _, _ => d

/-- A hint for messages that come from a linen predating lun's runtime. -/
def linenTooOldHint (d : Diagnostic) : Option String :=
  if (d.message.splitOn "Linen.Control.Reactive").length > 1 ||
     (d.message.splitOn "Linen.Control.Monad.Effect.Handler").length > 1 then
    some "the project's linen predates 1.3.0, which lun's functions and graphs need"
  else none

end Lun.Diagnostics
