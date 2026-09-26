/-
  Tests for `Lun.Driver`: the raw-string embedding cannot be closed by the
  text it embeds, names are quoted identifiers, and the generated files are
  the ones the build and the diagnostics rely on.
-/
import Lun.Driver

open Lun Lun.Driver

namespace LunTests.Driver

/-- `s` contains `sub`. -/
def has (s sub : String) : Bool := (s.splitOn sub).length > 1

-- ── Raw strings ─────────────────────────────────────────────────────────────

#guard rawString "Nat → Nat" == "r#\"Nat → Nat\"#"
#guard rawString "say \"hi\"" == "r#\"say \"hi\"\"#"
-- Text containing `"#` needs one more `#` than its longest such run.
#guard rawString "a\"#b" == "r##\"a\"#b\"##"
#guard rawString "x\"###y" == "r####\"x\"###y\"####"
-- `#` not after a quote does not count.
#guard rawString "#eval ##" == "r#\"#eval ##\"#"
#guard rawStringPrefixLength "a\"#b" == 4

-- ── Identifiers ─────────────────────────────────────────────────────────────

#guard ident "math.double" == "«math».«double»"
#guard ident "fun" == "«fun»"

-- ── Files ───────────────────────────────────────────────────────────────────

def spec : BuildSpec :=
  { source := { repo := { host := .github, segments := ["o", "r"], cloneUrl := "https://github.com/o/r.git" }
                branch := "main", commit := "".pushn 'a' 40, path := "", credentials := none }
    opens := []
    cells := [ { name := "math.double", module := "P.Math", function := "P.double", signature := "Nat → Eff [] Nat" }
             , { name := "add", module := "P.Math", function := "P.add", signature := "Nat → Nat → Eff [] Nat" } ]
    dags := [ { name := "main", program := "do\n  let x ← input \"x\" Nat\n  math.double x" } ] }

def input : Input := { spec, projectDir := "/work/src", packageName := "proj", toolchain := "leanprover/lean4:v4.34.0\n" }

#guard (files input).map (·.1) ==
  [ "lakefile.toml", "lean-toolchain", "LunDriver/Runtime.lean", "LunDriver/Cells.lean"
  , "LunDriver/Main.lean", "LunDriver/Cells/C0.lean", "LunDriver/Cells/C1.lean", "LunDriver/Dags/D0.lean" ]

#guard cellSource [] spec.cells[0]! ==
  "import LunDriver.Runtime\nimport «P».«Math»\nopen Control.Monad.Effect\n" ++
  "lun_cell \"math.double\" := «P».«double» : r#\"Nat → Eff [] Nat\"#\n"

#guard has (cellSource ["P", "Q.R"] spec.cells[0]!) "\nopen «P» «Q».«R»\n"

#guard dagSource [] spec.dags[0]! ==
  "import LunDriver.Cells\nopen Control.Reactive LunDriver.Cells\n" ++
  "lun_dag \"main\" := r#\"do\n  let x ← input \"x\" Nat\n  math.double x\"#\n"

-- The program starts on line 3, after `lun_dag "main" := r#"` (21 characters).
#guard dagProgramStart [] spec.dags[0]! == (3, 21)
#guard dagProgramStart ["P"] spec.dags[0]! == (4, 21)
#guard (((dagSource [] spec.dags[0]!).splitOn "\n")[2]!.drop 21).toString == "do"

#guard has (lakefileSource input) "path = \"/work/src\""
#guard has (lakefileSource input) "name = \"proj\""
#guard has (mainSource spec) "[(\"main\", LunDriver.Graphs.«main»)]"
#guard has (cellsSource spec) "[LunDriver.Impl.«math».«double», LunDriver.Impl.«add»]"
#guard cellTargets spec == ["LunDriver.Cells.C0", "LunDriver.Cells.C1"]
#guard moduleFile "LunDriver.Dags.D3" == "LunDriver/Dags/D3.lean"

-- The runtime is embedded.
#guard has runtimeSource "elab \"lun_cell \""
#guard has runtimeSource "elab \"lun_dag \""

end LunTests.Driver
