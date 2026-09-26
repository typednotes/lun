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
    "open": ["MyProject"],                       // optional: namespaces opened for signatures/DAGs
    "cells": [
      { "name": "math.double",                   // dotted; what DAGs call it by
        "module": "MyProject.Math",              // the module to import
        "function": "MyProject.Math.double",     // the function
        "signature": "Nat → Eff [] Nat" }        // its declared type
    ],
    "dags": [
      { "name": "main",
        "program": "do\n  let x ← input \"x\" Nat\n  math.double x" }
    ]
  }
  ```

  Parsing is the only place a request is interpreted: everything downstream
  receives a `BuildSpec` whose every string has passed `Lun.Validate`.
-/
import Lean.Data.Json
import Lun.Validate
import Lun.Liaison.Wire

namespace Lun

open Lean (Json)

-- ── Types ───────────────────────────────────────────────────────────────────

/-- Credentials for a private repository: a warrant for the connection, and
    the connection's account. Never persisted and never part of a build's id. -/
structure Credentials where
  warrant : Json
  account : String
  /-- What the warrant grants, read off its caveats. -/
  grant : Liaison.Grant

/-- Where the project comes from. -/
structure Source where
  repo : Validate.Repo
  branch : String
  commit : String
  /-- The project directory within the repository (`""` for its root). -/
  path : String
  credentials : Option Credentials

/-- A cell: a function of the project, under a name and a declared signature. -/
structure CellSpec where
  name : String
  module : String
  function : String
  signature : String
  deriving DecidableEq, Repr, Inhabited

/-- A DAG: a `Reactive` program over the cells. -/
structure DagSpec where
  name : String
  program : String
  deriving DecidableEq, Repr, Inhabited

/-- A validated build request. -/
structure BuildSpec where
  source : Source
  opens : List String
  cells : List CellSpec
  dags : List DagSpec

/-- At most this many cells, and this many DAGs, per build. -/
def maxCells : Nat := 256
def maxDags : Nat := 64

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

private def parseCredentials (j : Json) (repo : Validate.Repo) : Except String Credentials := do
  let warrant ← field j "source.credentials" "warrant"
  let account ← string j "source.credentials" "account"
  let grant ← Liaison.Grant.ofWarrant warrant |>.mapError ("source.credentials." ++ ·)
  let some provider := repo.host.provider?
    | throw "source.credentials: credentials are only usable for github.com and gitlab.com repositories"
  check (grant.provider == provider)
    s!"source.credentials: the warrant is for '{grant.provider}', the repository is on {provider}"
  check (Liaison.validAccount account grant)
    "source.credentials.account: must be {user_id}/{connection_id}, the connection being the warrant's resource"
  return { warrant, account, grant }

private def parseSource (j : Json) (allowLocal : Bool) : Except String Source := do
  let url ← string j "source" "url"
  let repo ← Validate.repo url allowLocal |>.mapError ("source.url: " ++ ·)
  let branch ← string j "source" "branch"
  check (Validate.branch branch) "source.branch: not a valid branch name"
  let commit ← string j "source" "commit"
  check (Validate.commit commit) "source.commit: must be a full 40- or 64-digit lowercase hex object name"
  let path ← match optional j "path" with
    | none => pure ""
    | some (.str p) => pure p
    | some _ => throw "source.path: must be a string"
  check (Validate.projectPath path) "source.path: must be relative, of plain components"
  let credentials ← (optional j "credentials").mapM (parseCredentials · repo)
  return { repo, branch, commit, path, credentials }

private def parseCell (j : Json) (i : Nat) : Except String CellSpec := do
  let ctx := s!"cells[{i}]"
  let name ← string j ctx "name"
  check (Validate.cellName name) s!"{ctx}.name: must be dotted identifiers, e.g. math.double"
  let module ← string j ctx "module"
  check (Validate.moduleName module) s!"{ctx}.module: not a Lean module name"
  let function ← string j ctx "function"
  check (Validate.declName function) s!"{ctx}.function: not a Lean declaration name"
  let signature ← string j ctx "signature"
  check (Validate.leanText signature (multiline := false) (maxLen := 4096))
    s!"{ctx}.signature: must be one line of Lean"
  return { name, module, function, signature }

private def parseDag (j : Json) (i : Nat) : Except String DagSpec := do
  let ctx := s!"dags[{i}]"
  let name ← string j ctx "name"
  check (Validate.cellName name) s!"{ctx}.name: must be dotted identifiers"
  let program ← string j ctx "program"
  check (Validate.leanText program (multiline := true)) s!"{ctx}.program: must be Lean text"
  return { name, program }

/-- The first element occurring twice, if any. -/
def firstDuplicate : List String → Option String
  | [] => none
  | x :: xs => if xs.contains x then some x else firstDuplicate xs

/-- Parse and validate a build request. `allowLocal` admits `file://`
    repositories (local mode, for tests). -/
def BuildSpec.parse (j : Json) (allowLocal : Bool := false) : Except String BuildSpec := do
  let source ← parseSource (← field j "request" "source") allowLocal
  let opens ← (← array j "request" "open").mapM fun
    | .str s => if Validate.declName s then pure s else throw s!"open: '{s}' is not a namespace"
    | _ => throw "open: must be strings"
  let cellJs ← array j "request" "cells"
  let dagJs ← array j "request" "dags"
  check (!cellJs.isEmpty) "cells: a build declares at least one cell"
  check (cellJs.length ≤ maxCells) s!"cells: at most {maxCells}"
  check (dagJs.length ≤ maxDags) s!"dags: at most {maxDags}"
  let cells ← cellJs.zipIdx.mapM fun (c, i) => parseCell c i
  let dags ← dagJs.zipIdx.mapM fun (d, i) => parseDag d i
  if let some n := firstDuplicate (cells.map (·.name)) then throw s!"cells: '{n}' is declared twice"
  if let some n := firstDuplicate (dags.map (·.name)) then throw s!"dags: '{n}' is declared twice"
  return { source, opens, cells, dags }

-- ── Canonical form ──────────────────────────────────────────────────────────

/-- The request without its credentials, in a canonical form (object keys
    are sorted by `Json`): what a build's id is computed from, and what is
    persisted with it. -/
def BuildSpec.canonical (s : BuildSpec) : Json :=
  Json.mkObj
    [ ("source", Json.mkObj
        [ ("url", s.source.repo.cloneUrl), ("branch", s.source.branch)
        , ("commit", s.source.commit), ("path", s.source.path) ])
    , ("open", Json.arr (s.opens.map Json.str).toArray)
    , ("cells", Json.arr (s.cells.map fun c => Json.mkObj
        [ ("name", c.name), ("module", c.module), ("function", c.function)
        , ("signature", c.signature) ]).toArray)
    , ("dags", Json.arr (s.dags.map fun d => Json.mkObj
        [("name", d.name), ("program", d.program)]).toArray) ]

end Lun
