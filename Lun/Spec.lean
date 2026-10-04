/-
  Lun.Spec — a build request, parsed and validated

  ```jsonc
  {
    "source": {
      "url": "https://github.com/owner/repo",   // as for `git clone`
      "branch": "main",
      "commit": "0123…cdef",                     // full object name; must be on `branch`
      "path": "lean",                            // optional: the directory holding the lakefile
      "credentials": {                           // optional: omitted for a public repository
        "warrant": { … },                        // minted by the app for the connection
        "account": "{user_id}/{connection_id}"
      }
    },
    "open": ["MyProject"],                       // optional: namespaces opened for signatures/graphs
    "functions": [
      { "name": "math.double",                   // dotted; what graphs call it by
        "module": "MyProject.Math",              // the module to import
        "function": "MyProject.Math.double",     // the function
        "signature": "Nat → Eff [] Nat" }        // its declared type
    ],
    "graphs": [
      { "name": "main",
        "program": "do\n  let x ← input \"x\" Nat\n  math.double x" }
    ]
  }
  ```

  Parsing is the only place a request is interpreted: everything downstream
  receives a `BuildSpec` whose every string has passed `Lun.Validate`.
-/
import Lean.Data.Json
import Linen.Data.Json
import Liaison.Wire
import Lun.Validate

namespace Lun

open Lean (Json)

/-- Parse request text before a map-backed JSON representation can erase
    duplicate authorization fields. The original bytes are checked first. -/
def parseRequestJson (text : String) : Except String Json := do
  let value ← Data.Json.Decode.decode text
  unless Liaison.Wire.uniqueKeys value do throw "duplicate JSON fields"
  Json.parse text

-- ── Types ───────────────────────────────────────────────────────────────────

/-- Credentials for a private repository: a warrant for the connection, and
    the connection's account. Never persisted and never part of a build's id.
    The warrant is decoded with liaison's own wire module (`Liaison.Wire`),
    so what lun forwards is what liaison parses. -/
structure Credentials where
  warrant : Liaison.Warrant
  account : String

/-- Where the project comes from. -/
structure Source where
  repo : System.Git.Repository
  branch : String
  commit : String
  /-- The project directory within the repository (`""` for its root). -/
  path : String
  credentials : Option Credentials
  /-- Local working-tree input, snapshotted before computing the build id.
      When present, `repo` names the folder and branch/commit are unused. -/
  directory : Option String := none

/-- A function of the project, under a name and a declared signature. -/
structure FunctionSpec where
  name : String
  module : String
  function : String
  signature : String
  /-- A user-owned output constraint, independent of the generated signature. -/
  outputType : Option String := none
  /-- A resumable producer: arguments followed by `Nat → Option S → Eff effs
      (List B × S × Option Nat)`. Its graph output is `B`. -/
  producer : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- A graph: a `Reactive` program over the functions. -/
structure GraphSpec where
  name : String
  program : String
  /-- Named direct arguments, in order; omitted for legacy graphs. -/
  dependencies : List (String × List String) := []
  /-- User-owned source types (UI/endpoint inputs have no function signature). -/
  inputTypes : List (String × String) := []
  deriving DecidableEq, Repr, Inhabited

/-- A validated build request. -/
structure BuildSpec where
  source : Source
  opens : List String
  functions : List FunctionSpec
  graphs : List GraphSpec

/-- At most this many functions, and this many graphs, per build. -/
def maxFunctions : Nat := 256
def maxGraphs : Nat := 64

-- ── Parsing ─────────────────────────────────────────────────────────────────

private def field (j : Json) (ctx name : String) : Except String Json :=
  (j.getObjVal? name).mapError fun _ => s!"{ctx}: missing \"{name}\""

private def string (j : Json) (ctx name : String) : Except String String := do
  match ← field j ctx name with
  | .str s => pure s
  | _ => throw s!"{ctx}.{name}: must be a string"

private def optional (j : Json) (name : String) : Option Json :=
  match j.getObjVal? name with
  | .ok .null => none
  | .ok v => some v
  | .error _ => none

private def array (j : Json) (ctx name : String) : Except String (List Json) :=
  match optional j name with
  | none => pure []
  | some (.arr xs) => pure xs.toList
  | some _ => throw s!"{ctx}.{name}: must be an array"

private def check (ok : Bool) (msg : String) : Except String Unit :=
  if ok then pure () else throw msg

private def parseCredentials (j : Json) (repo : System.Git.Repository) : Except String Credentials := do
  let warrantJson ← field j "source.credentials" "warrant"
  let account ← string j "source.credentials" "account"
  let warrant ← (Data.Json.Decode.decode warrantJson.compress >>= Liaison.Wire.decodeWarrant)
    |>.mapError ("source.credentials." ++ ·)
  -- What the warrant is for; `now` and `cost` are filled in per call.
  let grant ← Liaison.Wire.Request.ofWarrant warrant 0 0 |>.mapError ("source.credentials." ++ ·)
  let some provider := repo.host.provider?
    | throw "source.credentials: credentials are only usable for github.com and gitlab.com repositories"
  check (grant.provider.value == provider)
    s!"source.credentials: the warrant is for '{grant.provider.value}', the repository is on {provider}"
  check (Liaison.Wire.accountMatchesResource account grant.resource.value)
    "source.credentials.account: must be {user_id}/{connection_id}, the connection being the warrant's resource"
  return { warrant, account }

private def parseSource (j : Json) (allowLocal : Bool) : Except String Source := do
  let path ← match optional j "path" with
    | none => pure ""
    | some (.str p) => pure p
    | some _ => throw "source.path: must be a string"
  check (Validate.projectPath path) "source.path: must be relative, of plain components"
  if let some directory := optional j "directory" then
    check allowLocal "source.directory: folders are only accepted in local mode"
    let directory ← directory.getStr? |>.mapError (fun _ => "source.directory: must be a string")
    check (Validate.localDirectory directory) "source.directory: must be an absolute folder path without dot segments"
    for name in ["url", "branch", "commit", "credentials"] do
      check ((optional j name).isNone) s!"source.directory: cannot be combined with {name}"
    return { repo := { host := .local, segments := (directory.splitOn "/").drop 1,
                       cloneUrl := "file://" ++ directory },
             branch := "", commit := "", path, credentials := none, directory := some directory }
  let url ← string j "source" "url"
  let repo ← System.Git.Repository.parse url allowLocal |>.mapError ("source.url: " ++ ·)
  let branch ← string j "source" "branch"
  check (System.Git.isBranchName branch) "source.branch: not a valid branch name"
  let commit ← string j "source" "commit"
  check (Validate.commit commit) "source.commit: must be a full 40- or 64-digit lowercase hex object name"
  let credentials ← (optional j "credentials").mapM (parseCredentials · repo)
  return { repo, branch, commit, path, credentials }

private def parseFunction (j : Json) (i : Nat) : Except String FunctionSpec := do
  let ctx := s!"functions[{i}]"
  let name ← string j ctx "name"
  check (Validate.functionName name) s!"{ctx}.name: must be dotted identifiers, e.g. math.double"
  let module ← string j ctx "module"
  check (Validate.moduleName module) s!"{ctx}.module: not a Lean module name"
  let function ← string j ctx "function"
  check (Validate.declName function) s!"{ctx}.function: not a Lean declaration name"
  let signature ← string j ctx "signature"
  check (Validate.leanText signature (multiline := false) (maxLen := 4096))
    s!"{ctx}.signature: must be one line of Lean"
  let outputType ← match optional j "outputType" with
    | none => pure none
    | some (.str t) =>
      check (Validate.leanText t (multiline := false) (maxLen := 512)) s!"{ctx}.outputType: must be one Lean type"
      pure (some t)
    | some _ => throw s!"{ctx}.outputType: must be a string"
  let producer ← match optional j "producer" with
    | none => pure false
    | some (.bool value) => pure value
    | some _ => throw s!"{ctx}.producer: must be a boolean"
  return { name, module, function, signature, outputType, producer }

private def parseGraph (j : Json) (i : Nat) : Except String GraphSpec := do
  let ctx := s!"graphs[{i}]"
  let name ← string j ctx "name"
  check (Validate.functionName name) s!"{ctx}.name: must be dotted identifiers"
  let program ← string j ctx "program"
  check (Validate.leanText program (multiline := true)) s!"{ctx}.program: must be Lean text"
  let dependencies ← match optional j "dependencies" with
    | none => pure []
    | some (.obj values) => values.toList.mapM fun (cell, deps) => do
      check (Validate.functionName cell) s!"{ctx}.dependencies: invalid cell name"
      let names ← deps.getArr?
      let names ← names.toList.mapM fun value => do
        let value ← value.getStr?
        check (Validate.functionName value) s!"{ctx}.dependencies: invalid argument name"
        pure value
      pure (cell, names)
    | some _ => throw s!"{ctx}.dependencies: must be an object"
  let inputTypes ← match optional j "inputTypes" with
    | none => pure []
    | some (.obj values) => values.toList.mapM fun (input, value) => do
      check (Validate.functionName input) s!"{ctx}.inputTypes: invalid input name"
       let type ← value.getStr? |>.mapError (fun _ => s!"{ctx}.inputTypes: each type must be a string")
      check (Validate.leanText type (multiline := false) (maxLen := 512))
        s!"{ctx}.inputTypes: must contain Lean types"
      pure (input, type)
    | some _ => throw s!"{ctx}.inputTypes: must be an object"
  return { name, program, dependencies, inputTypes }

/-- The first element occurring twice, if any. -/
def firstDuplicate : List String → Option String
  | [] => none
  | x :: xs => if xs.contains x then some x else firstDuplicate xs

/-- Parse and validate a build request. `allowLocal` admits `file://`
    repositories and working folders (local development). -/
def BuildSpec.parse (j : Json) (allowLocal : Bool := false) : Except String BuildSpec := do
  let source ← parseSource (← field j "request" "source") allowLocal
  let opens ← (← array j "request" "open").mapM fun
    | .str s => if Validate.declName s then pure s else throw s!"open: '{s}' is not a namespace"
    | _ => throw "open: must be strings"
  let functionJs ← array j "request" "functions"
  let graphJs ← array j "request" "graphs"
  check (!functionJs.isEmpty) "functions: a build declares at least one function"
  check (functionJs.length ≤ maxFunctions) s!"functions: at most {maxFunctions}"
  check (graphJs.length ≤ maxGraphs) s!"graphs: at most {maxGraphs}"
  let functions ← functionJs.zipIdx.mapM fun (c, i) => parseFunction c i
  let graphs ← graphJs.zipIdx.mapM fun (d, i) => parseGraph d i
  if let some n := firstDuplicate (functions.map (·.name)) then throw s!"functions: '{n}' is declared twice"
  if let some n := firstDuplicate (graphs.map (·.name)) then throw s!"graphs: '{n}' is declared twice"
  return { source, opens, functions, graphs }

-- ── Canonical form ──────────────────────────────────────────────────────────

/-- The request without its credentials, in a canonical form (object keys
    are sorted by `Json`): what a build's id is computed from, and what is
    persisted with it. -/
def BuildSpec.canonical (s : BuildSpec) : Json :=
  Json.mkObj
    [ ("source", Json.mkObj
        (match s.source.directory with
         | some directory => [("directory", Json.str directory), ("path", Json.str s.source.path)]
         | none => [ ("url", s.source.repo.cloneUrl), ("branch", s.source.branch)
                   , ("commit", s.source.commit), ("path", s.source.path) ]))
    , ("open", Json.arr (s.opens.map Json.str).toArray)
    , ("functions", Json.arr (s.functions.map fun c => Json.mkObj <|
        [ ("name", Json.str c.name), ("module", Json.str c.module), ("function", Json.str c.function)
         , ("signature", Json.str c.signature) ] ++ (c.outputType.map fun t => [("outputType", Json.str t)]).getD [] ++
         (if c.producer then [("producer", Json.bool true)] else [])).toArray)
    , ("graphs", Json.arr (s.graphs.map fun d => Json.mkObj
          [("name", d.name), ("program", d.program), ("dependencies", Json.mkObj (d.dependencies.map fun (n, args) => (n, Lean.toJson args))),
           ("inputTypes", Json.mkObj (d.inputTypes.map fun (n, t) => (n, Json.str t)))]).toArray) ]

end Lun
