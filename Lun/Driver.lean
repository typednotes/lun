/-
  Lun.Driver — the Lake package lun generates around a user project

  ```
  driver/
    lakefile.toml            requires the user project by path
    lean-toolchain           the user project's
    LunDriver/Runtime.lean  template/LunDriver/Runtime.lean, verbatim
    LunDriver/Cells/C<i>.lean   one module per cell: `lun_cell …`
    LunDriver/Cells.lean        the cells, as a list
    LunDriver/Dags/D<j>.lean    one module per DAG: `lun_dag …`
    LunDriver/Main.lean         the `lun-driver` executable
  ```

  One module per cell and per DAG is what lets lun attribute every error to
  the cell or DAG it belongs to (`Lun.Diagnostics`), and lets Lake check the
  cells independently.

  Generation is pure. Nothing from a request is spliced into a generated file
  as code: names are validated identifiers (and written `«quoted»`), and
  signatures and DAG programs are embedded as raw string literals, which the
  runtime parses as exactly one term each.
-/
import Lun.Spec

namespace Lun.Driver

/-- The runtime every driver shares, embedded in lun at compile time. -/
def runtimeSource : String := include_str "../template/LunDriver/Runtime.lean"

/-- What a driver is generated from. -/
structure Input where
  spec : BuildSpec
  /-- The user project's directory (absolute). -/
  projectDir : System.FilePath
  /-- The user project's package name, as its manifest declares it. -/
  packageName : String
  /-- The user project's `lean-toolchain`. -/
  toolchain : String

-- ── Lean text ───────────────────────────────────────────────────────────────

/-- The longest run of `#` directly following a `"` in `s`. -/
def longestHashRun (s : String) : Nat :=
  let rec go : List Char → Bool → Nat → Nat → Nat
    | [], _, _, best => best
    | c :: cs, afterQuote, run, best =>
      if c == '"' then go cs true 0 best
      else if c == '#' && afterQuote then go cs true (run + 1) (max best (run + 1))
      else go cs false 0 best
  go s.toList false 0 0

/-- `s` as a Lean raw string literal, `r#…#"s"#…#`, with more `#`s than any
    `"#…#` run inside it, so nothing in `s` can close it. -/
def rawString (s : String) : String :=
  let hashes := "".pushn '#' (longestHashRun s + 1)
  s!"r{hashes}\"{s}\"{hashes}"

/-- The characters `rawString` puts before the content. -/
def rawStringPrefixLength (s : String) : Nat := longestHashRun s + 3

/-- A dotted name as a Lean identifier with every component `«quoted»`, so no
    component can collide with a keyword. -/
def ident (dotted : String) : String :=
  ".".intercalate ((dotted.splitOn ".").map fun c => s!"«{c}»")

/-- `s` as a Lean string literal (for names, which are validated identifiers). -/
def strLit (s : String) : String := s.quote

-- ── Modules ─────────────────────────────────────────────────────────────────

/-- The module checking cell `i`. -/
def cellModule (i : Nat) : String := s!"LunDriver.Cells.C{i}"

/-- The module checking DAG `j`. -/
def dagModule (j : Nat) : String := s!"LunDriver.Dags.D{j}"

/-- A module's file, relative to the driver. -/
def moduleFile (m : String) : String := "/".intercalate (m.splitOn ".") ++ ".lean"

private def opensLine (opens : List String) : String :=
  if opens.isEmpty then "" else s!"open {" ".intercalate (opens.map ident)}\n"

/-- The module for cell `c`. -/
def cellSource (opens : List String) (c : CellSpec) : String :=
  s!"import LunDriver.Runtime\nimport {ident c.module}\n" ++
  "open Control.Monad.Effect\n" ++ opensLine opens ++
  s!"lun_cell {strLit c.name} := {ident c.function} : {rawString c.signature}\n"

/-- The line of a DAG module on which its program starts (1-based), and the
    column its first line starts at. -/
def dagProgramStart (opens : List String) (d : DagSpec) : Nat × Nat :=
  (if opens.isEmpty then 3 else 4,
   s!"lun_dag {strLit d.name} := ".length + rawStringPrefixLength d.program)

/-- The module for DAG `d`. -/
def dagSource (opens : List String) (d : DagSpec) : String :=
  "import LunDriver.Cells\n" ++
  "open Control.Reactive LunDriver.Cells\n" ++ opensLine opens ++
  s!"lun_dag {strLit d.name} := {rawString d.program}\n"

/-- The list of all cells, which the DAG checks and the executable use. -/
def cellsSource (spec : BuildSpec) : String :=
  let imports := (List.range spec.cells.length).map fun i => s!"import {cellModule i}\n"
  let impls := spec.cells.map fun c => s!"LunDriver.Impl.{ident c.name}"
  String.join imports ++
  s!"\ndef LunDriver.cellImpls : List LunDriver.CellImpl :=\n  [{", ".intercalate impls}]\n" ++
  "\ndef LunDriver.cellArities : List (String × Nat) :=\n" ++
  "  LunDriver.cellImpls.map fun c => (c.name, c.arity)\n"

/-- The executable. -/
def mainSource (spec : BuildSpec) : String :=
  let imports := (List.range spec.dags.length).map fun j => s!"import {dagModule j}\n"
  let dags := spec.dags.map fun d => s!"({strLit d.name}, LunDriver.Graphs.{ident d.name})"
  "import LunDriver.Cells\n" ++ String.join imports ++
  s!"\ndef main (args : List String) : IO UInt32 :=\n" ++
  s!"  LunDriver.driverMain LunDriver.cellImpls [{", ".intercalate dags}] args\n"

/-- The driver's `lakefile.toml`. -/
def lakefileSource (d : Input) : String :=
  s!"name = \"lun_driver\"\n" ++
  s!"defaultTargets = [\"lun-driver\"]\n\n" ++
  s!"[[require]]\nname = {d.packageName.quote}\npath = {d.projectDir.toString.quote}\n\n" ++
  s!"[[lean_lib]]\nname = \"LunDriver\"\n\n" ++
  s!"[[lean_exe]]\nname = \"lun-driver\"\nroot = \"LunDriver.Main\"\n"

/-- Every file of the driver: `(path relative to the driver, contents)`. -/
def files (d : Input) : List (String × String) :=
  let spec := d.spec
  [ ("lakefile.toml", lakefileSource d)
  , ("lean-toolchain", d.toolchain)
  , ("LunDriver/Runtime.lean", runtimeSource)
  , ("LunDriver/Cells.lean", cellsSource spec)
  , ("LunDriver/Main.lean", mainSource spec) ] ++
  spec.cells.zipIdx.map (fun (c, i) => (moduleFile (cellModule i), cellSource spec.opens c)) ++
  spec.dags.zipIdx.map (fun (dg, j) => (moduleFile (dagModule j), dagSource spec.opens dg))

/-- The build targets that check the cells (and build the project). -/
def cellTargets (spec : BuildSpec) : List String :=
  (List.range spec.cells.length).map cellModule

end Lun.Driver
