/-
  Lun.Driver — the Lake package lun generates around a user project

  ```
  driver/
    lakefile.toml            requires the user project by path
    lean-toolchain           the user project's
    LunDriver/Runtime.lean  template/LunDriver/Runtime.lean, verbatim
    LunDriver/Functions/F<i>.lean  one module per function: `lun_function …`
    LunDriver/Functions.lean       the functions, as a list
    LunDriver/Graphs/G<j>.lean     one module per graph: `lun_graph …`
    LunDriver/Main.lean         the `lun-driver` executable
  ```

  One module per function and per graph is what lets lun attribute every error to
  the function or graph it belongs to (`Lun.Diagnostics`), and lets Lake check the
  functions independently.

  Generation is pure. Nothing from a request is spliced into a generated file
  as code: names are validated identifiers (and written `«quoted»`), and
  signatures and graph programs are embedded as raw string literals, which the
  runtime parses as exactly one term each.
-/
import Lun.Spec
import Lun.Manifest

namespace Lun.Driver

/-- The runtime every driver shares, embedded in lun at compile time. -/
def runtimeSource : String := include_str "../template/LunDriver/Runtime.lean"

def temporarySource : String := include_str "../template/LunDriver/temporary.py"

/-- Cached drivers from before bounded execution must never receive calls. -/
def runtimeContract : String := "bounded-eff-v1"

/-- What a driver is generated from. -/
structure Input where
  spec : BuildSpec
  /-- The user project's directory (absolute). -/
  projectDir : System.FilePath
  /-- The user project's package name, as its manifest declares it. -/
  packageName : String
  /-- The user project's `lean-toolchain`. -/
  toolchain : String
  liaisonSdkPath : Option System.FilePath := none
  linenSource : Option Manifest.Source := none
  /-- Native driver bindings require libpq even when lun itself does not. -/
  nativeLinkArgs : List String := ["-lpq"]

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

/-- The module checking function `i`. -/
def functionModule (i : Nat) : String := s!"LunDriver.Functions.F{i}"

/-- The module checking graph `j`. -/
def graphModule (j : Nat) : String := s!"LunDriver.Graphs.G{j}"

/-- A module's file, relative to the driver. -/
def moduleFile (m : String) : String := "/".intercalate (m.splitOn ".") ++ ".lean"

private def opensLine (opens : List String) : String :=
  if opens.isEmpty then "" else s!"open {" ".intercalate (opens.map ident)}\n"

/-- The module for function `c`. -/
def functionSource (opens : List String) (c : FunctionSpec) : String :=
  s!"import LunDriver.Runtime\nimport {ident c.module}\n" ++
  "open Control.Monad.Effect\n" ++ opensLine opens ++
  s!"lun_function {strLit c.name} := {ident c.function} : {rawString c.signature}\n" ++
  (c.outputType.map fun t => s!"lun_output {strLit c.name} : {rawString t}\n").getD ""

/-- The line of a graph module on which its program starts (1-based), and the
    column its first line starts at. -/
def graphProgramStart (opens : List String) (d : GraphSpec) : Nat × Nat :=
  ((if opens.isEmpty then 3 else 4) + (if d.inputTypes.isEmpty then 0 else 2),
   (s!"lun_graph {strLit d.name}" ++ (if d.inputTypes.isEmpty then "" else s!" using_input LunDriver.Inputs.{ident d.name}.input") ++ " := ").length + rawStringPrefixLength d.program)

/-- The module for graph `d`. -/
def graphSource (opens : List String) (d : GraphSpec) : String :=
  "import LunDriver.Functions\n" ++
  (if d.inputTypes.isEmpty then "open Control.Reactive LunDriver.Dsl LunDriver.Functions\n"
   else "open Control.Reactive LunDriver.Functions\n") ++ opensLine opens ++
   (if d.inputTypes.isEmpty then "" else
     s!"lun_inputs {strLit d.name} := {rawString (Lean.toJson d.inputTypes).compress}\nopen LunDriver.Inputs.{ident d.name}\n") ++
   s!"lun_graph {strLit d.name}" ++
   (if d.inputTypes.isEmpty then "" else s!" using_input LunDriver.Inputs.{ident d.name}.input") ++
   s!" := {rawString d.program}\n" ++
  (if d.dependencies.isEmpty then "" else
    s!"lun_dependencies {strLit d.name} := {rawString (Lean.toJson d.dependencies).compress}\n")

/-- The list of all functions, which the graph checks and the executable use. -/
def functionsSource (spec : BuildSpec) : String :=
  let imports := (List.range spec.functions.length).map fun i => s!"import {functionModule i}\n"
  let impls := spec.functions.map fun c => s!"LunDriver.Impl.{ident c.name}"
  String.join imports ++
  s!"\ndef LunDriver.functionImpls : List LunDriver.FunctionImpl :=\n  [{", ".intercalate impls}]\n"

/-- The executable. -/
def mainSource (spec : BuildSpec) : String :=
  let imports := (List.range spec.graphs.length).map fun j => s!"import {graphModule j}\n"
  let graphs := spec.graphs.map fun d =>
    let graphNamespace := if !d.dependencies.isEmpty then "ConstrainedGraphs" else if !d.inputTypes.isEmpty then "SourceConstrainedGraphs" else "Graphs"
    s!"({strLit d.name}, LunDriver.{graphNamespace}.{ident d.name})"
  "import LunDriver.Functions\n" ++ String.join imports ++
  s!"\ndef main (args : List String) : IO UInt32 :=\n" ++
  s!"  LunDriver.driverMain LunDriver.functionImpls [{", ".intercalate graphs}] args\n"

/-- The driver's `lakefile.toml`. -/
def lakefileSource (d : Input) : String :=
  s!"name = \"lun_driver\"\n" ++
  s!"defaultTargets = [\"lun-driver\"]\n\n" ++
  (match d.linenSource with
    | some (.path path) =>
      let path : System.FilePath := path
      let path := if path.isAbsolute then path else d.projectDir / path
      s!"[[require]]\nname = \"linen\"\npath = {path.toString.quote}\n\n"
    | some (.git url rev _) => s!"[[require]]\nname = \"linen\"\ngit = {url.quote}\nrev = {rev.quote}\n\n"
    | none => "") ++
  s!"[[require]]\nname = {d.packageName.quote}\npath = {d.projectDir.toString.quote}\n\n" ++
  (match d.liaisonSdkPath with
    | some path => s!"[[require]]\nname = \"liaison\"\npath = {path.toString.quote}\n\n"
    | none => "[[require]]\nname = \"liaison\"\ngit = \"https://github.com/typednotes/liaison\"\nrev = \"v0.6.0\"\n\n") ++
  s!"[[lean_lib]]\nname = \"LunDriver\"\n\n" ++
  s!"[[lean_exe]]\nname = \"lun-driver\"\nroot = \"LunDriver.Main\"\n" ++
  s!"moreLinkArgs = [{", ".intercalate (d.nativeLinkArgs.map String.quote)}]\n"

/-- Every file of the driver: `(path relative to the driver, contents)`. -/
def files (d : Input) : List (String × String) :=
  let spec := d.spec
  [ ("lakefile.toml", lakefileSource d)
  , ("lean-toolchain", d.toolchain)
   , ("LunDriver/Runtime.lean", runtimeSource)
   , ("LunDriver/temporary.py", temporarySource)
  , ("LunDriver/Functions.lean", functionsSource spec)
  , ("LunDriver/Main.lean", mainSource spec) ] ++
  spec.functions.zipIdx.map (fun (c, i) => (moduleFile (functionModule i), functionSource spec.opens c)) ++
  spec.graphs.zipIdx.map (fun (dg, j) => (moduleFile (graphModule j), graphSource spec.opens dg))

/-- The build targets that check the functions (and build the project). -/
def functionTargets (spec : BuildSpec) : List String :=
  (List.range spec.functions.length).map functionModule

end Lun.Driver
