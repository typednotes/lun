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
    functions := [ { name := "math.double", module := "P.Math", function := "P.double", signature := "Nat → Eff [] Nat" }
             , { name := "add", module := "P.Math", function := "P.add", signature := "Nat → Nat → Eff [] Nat" } ]
    graphs := [ { name := "main", program := "do\n  let x ← input \"x\" Nat\n  math.double x" } ] }

def input : Input := { spec, projectDir := "/work/src", packageName := "proj", toolchain := "leanprover/lean4:v4.34.0\n" }

#guard (files input).map (·.1) ==
  [ "lakefile.toml", "lean-toolchain", "LunDriver/Runtime.lean", "LunDriver/temporary.py", "LunDriver/Functions.lean"
  , "LunDriver/Main.lean", "LunDriver/Functions/F0.lean", "LunDriver/Functions/F1.lean", "LunDriver/Graphs/G0.lean" ]

#guard functionSource [] spec.functions[0]! ==
  "import LunDriver.Runtime\nimport «P».«Math»\nopen Control.Monad.Effect\n" ++
  "lun_function \"math.double\" := «P».«double» : r#\"Nat → Eff [] Nat\"#\n"

#guard has (functionSource ["P", "Q.R"] spec.functions[0]!) "\nopen «P» «Q».«R»\n"

#guard graphSource [] spec.graphs[0]! ==
  "import LunDriver.Functions\nopen Control.Reactive LunDriver.Dsl LunDriver.Functions\n" ++
  "lun_graph \"main\" := r#\"do\n  let x ← input \"x\" Nat\n  math.double x\"#\n"

-- The program starts on line 3, after `lun_graph "main" := r#"` (23 characters).
#guard graphProgramStart [] spec.graphs[0]! == (3, 23)
#guard graphProgramStart ["P"] spec.graphs[0]! == (4, 23)
#guard (((graphSource [] spec.graphs[0]!).splitOn "\n")[2]!.drop 23).toString == "do"

#guard has (lakefileSource input) "path = \"/work/src\""
#guard has (lakefileSource input) "name = \"proj\""
#guard has (mainSource spec) "[(\"main\", LunDriver.Graphs.«main»)]"
#guard has (functionsSource spec) "[LunDriver.Impl.«math».«double», LunDriver.Impl.«add»]"
#guard functionTargets spec == ["LunDriver.Functions.F0", "LunDriver.Functions.F1"]
#guard moduleFile "LunDriver.Graphs.G3" == "LunDriver/Graphs/G3.lean"

-- The runtime is embedded.
#guard has runtimeSource "elab \"lun_function \""
#guard has runtimeSource "elab \"lun_graph \""
#guard has runtimeSource ("def runtimeContract : String := " ++ runtimeContract.quote)

def constrained : GraphSpec := { spec.graphs[0]! with inputTypes := [("x", "Nat")], dependencies := [("math.double", ["x"])] }
#guard has (graphSource [] constrained) "lun_inputs"
#guard has (graphSource [] constrained) "using_input LunDriver.Inputs."
#guard has (graphSource [] constrained) "lun_dependencies"
#guard (graphProgramStart [] constrained).1 == 5

end LunTests.Driver
