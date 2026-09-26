/-
  Lun.Diagnostics — lake's output, as diagnostics about cells and DAGs

  `lake build` prints each message as `error: FILE:LINE:COL: text`, the text
  possibly continuing on following lines. Because the driver has one module
  per cell and per DAG (`Lun.Driver`), the file alone says what a message is
  about: `LunDriver/Cells/C<i>.lean` is cell `i`, `LunDriver/Dags/D<j>.lean`
  is DAG `j` (whose line numbers are translated back into the DAG program),
  any other driver file is lun's own fault, and anything else is the
  project's.
-/
import Lean.Data.Json

namespace Lun.Diagnostics

open Lean (Json ToJson toJson)

/-- What a message is about. -/
inductive Scope where
  /-- The cell at this index in the request. -/
  | cell (index : Nat)
  /-- The DAG at this index in the request. -/
  | dag (index : Nat)
  /-- The user project itself (its own modules failed to build). -/
  | project
  /-- lun's generated code — a lun bug, or a project whose linen is too old. -/
  | driver
  /-- No file: a failure of the build as a whole. -/
  | build
  deriving DecidableEq, Repr

/-- One message. -/
structure Diagnostic where
  severity : String
  file : Option String
  line : Option Nat
  column : Option Nat
  message : String
  deriving DecidableEq, Repr, Inhabited

/-- Line prefixes that start something other than a continuation. -/
private def starters : List String :=
  ["error: ", "warning: ", "info: ", "trace: ", "✖ ", "✔ ", "⚠ ", "Some required targets", "Build completed"]

/-- Split `FILE:LINE:COL: text`. -/
def splitLocation (s : String) : Option String × Option Nat × Option Nat × String :=
  match s.splitOn ":" with
  | file :: line :: col :: rest =>
    match line.toNat?, col.trimAscii.toString.toNat? with
    | some l, some c =>
      (some file, some l, some c, (":".intercalate rest).trimAsciiStart.toString)
    | _, _ => (none, none, none, s)
  | _ => (none, none, none, s)

/-- The `error:` and `warning:` messages of a lake log, in order. -/
def parse (log : String) : List Diagnostic :=
  let lines := log.splitOn "\n"
  let (done, cur) := lines.foldl (init := (([] : List Diagnostic), (none : Option Diagnostic)))
    fun (done, cur) line =>
      let flush := match cur with | some d => d :: done | none => done
      let start (sev pfx : String) : Option Diagnostic :=
        if line.startsWith pfx then
          let (file, l, c, text) := splitLocation (line.drop pfx.length).toString
          some { severity := sev, file, line := l, column := c, message := text }
        else none
      match start "error" "error: " <|> start "warning" "warning: " with
      | some d => (flush, some d)
      | none =>
        if starters.any (fun (p : String) => line.startsWith p) then (flush, none)
        else match cur with
          | some d => (done, some { d with message := d.message ++ "\n" ++ line })
          | none => (done, none)
  let all := (match cur with | some d => d :: done | none => done).reverse
  all.map fun d => { d with message := d.message.trimAsciiEnd.toString }

/-- `LunDriver/Cells/C12.lean` ↦ `12`, for `kind = "Cells"`, `letter = "C"`. -/
private def indexIn (file kind letter : String) : Option Nat :=
  let pfx := s!"LunDriver/{kind}/{letter}"
  let file := if file.startsWith "./" then (file.drop 2).toString else file
  if file.startsWith pfx && file.endsWith ".lean" then
    ((file.drop pfx.length).dropEnd 5).toString.toNat?
  else none

/-- What a diagnostic is about. -/
def Diagnostic.scope (d : Diagnostic) : Scope :=
  match d.file with
  | none => .build
  | some f =>
    match indexIn f "Cells" "C", indexIn f "Dags" "D" with
    | some i, _ => .cell i
    | _, some j => .dag j
    | _, _ =>
      let f := if f.startsWith "./" then (f.drop 2).toString else f
      if f.startsWith "LunDriver/" then .driver else .project

/-- Translate a DAG module position to a position in the DAG program, given
    where the program starts (`Lun.Driver.dagProgramStart`). -/
def Diagnostic.inProgram (d : Diagnostic) (start : Nat × Nat) : Diagnostic :=
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
    some "the project's linen predates 1.3.0, which lun's cells and DAGs need"
  else none

instance : ToJson Diagnostic where
  toJson d := Json.mkObj <|
    [("severity", toJson d.severity), ("message", toJson d.message)] ++
    (d.file.map fun f => [("file", toJson f)]).getD [] ++
    (d.line.map fun l => [("line", toJson l)]).getD [] ++
    (d.column.map fun c => [("column", toJson c)]).getD []

end Lun.Diagnostics
