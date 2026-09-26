/-
  Lun.Manifest — what a user project may depend on

  A project lun builds may depend on **linen and nothing else**: the cells'
  types (`Eff`, the effects, `Control.Reactive`) come from linen or the Lean
  distribution, and every other dependency would be code lun has not
  vetted, run at build time and linked into the cells.

  The check reads the project's committed `lake-manifest.json` — the lock
  file, which lists every package, transitive ones included — and requires
  it to exist, so that what is built is pinned. linen itself has no
  dependencies, so its lock file never adds any.
-/
import Lean.Data.Json

namespace Lun.Manifest

open Lean (Json)

/-- linen's repository, as a `require … from git` names it. -/
def linenUrl : String := "https://github.com/typednotes/linen"

/-- How a locked package is obtained. -/
inductive Source where
  | git (url rev : String) (inputRev : Option String)
  | path (dir : String)
  deriving DecidableEq, Repr

/-- One locked package. -/
structure Package where
  name : String
  source : Source
  deriving DecidableEq, Repr

/-- A project's lock file. -/
structure Manifest where
  /-- The project's own package name. -/
  name : String
  packages : List Package
  deriving DecidableEq, Repr

/-- A package name lun is willing to write into a generated lakefile. -/
def validPackageName (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 128 && s.all fun c => c.isAlphanum || c == '_' || c == '-'

/-- Parse `lake-manifest.json`. -/
def parse (text : String) : Except String Manifest := do
  let j ← Json.parse text |>.mapError ("lake-manifest.json is not JSON: " ++ ·)
  let name ← j.getObjValAs? String "name" |>.mapError fun _ => "lake-manifest.json: no \"name\""
  let pkgs ← j.getObjValAs? (Array Json) "packages" |>.mapError fun _ =>
    "lake-manifest.json: no \"packages\""
  let packages ← pkgs.toList.mapM fun p => do
    let pname ← p.getObjValAs? String "name" |>.mapError fun _ => "lake-manifest.json: a package has no name"
    match (p.getObjValAs? String "type").toOption with
    | some "git" =>
      let url ← p.getObjValAs? String "url" |>.mapError fun _ => s!"lake-manifest.json: {pname} has no url"
      let rev ← p.getObjValAs? String "rev" |>.mapError fun _ => s!"lake-manifest.json: {pname} has no rev"
      pure { name := pname, source := .git url rev (p.getObjValAs? String "inputRev").toOption }
    | some "path" =>
      let dir ← p.getObjValAs? String "dir" |>.mapError fun _ => s!"lake-manifest.json: {pname} has no dir"
      pure { name := pname, source := .path dir }
    | _ => throw s!"lake-manifest.json: {pname} has an unknown type"
  return { name, packages }

/-- `url` names linen's repository (with or without `.git` or a trailing `/`). -/
def isLinenUrl (url : String) : Bool :=
  let u := if url.endsWith "/" then (url.dropEnd 1).toString else url
  let u := if u.endsWith ".git" then (u.dropEnd 4).toString else u
  u == linenUrl

/-- The project depends on linen and nothing else. A path dependency (on a
    local linen checkout) is accepted only when `allowPath` (local mode). -/
def check (m : Manifest) (allowPath : Bool := false) : Except String Unit := do
  unless validPackageName m.name do
    throw s!"the project's package name '{m.name}' is not [A-Za-z0-9_-]+"
  for p in m.packages do
    unless p.name == "linen" do
      throw s!"the project depends on '{p.name}'; a lun project may depend on linen only"
    match p.source with
    | .git url _ _ =>
      unless isLinenUrl url do
        throw s!"the project takes linen from {url}, not {linenUrl}"
    | .path _ =>
      unless allowPath do throw "the project takes linen from a local path; pin it by git tag"

/-- The linen revision the project is locked to, if it takes linen from git. -/
def linenRev? (m : Manifest) : Option String :=
  m.packages.findSome? fun p => match p.source with
    | .git _ rev _ => if p.name == "linen" then some rev else none
    | _ => none

end Lun.Manifest
