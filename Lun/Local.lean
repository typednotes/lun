/-
  Lun.Local — immutable snapshots of local working folders. The user's folder
  is never modified. A private Git repository records the copied tree, including
  uncommitted/untracked files, excluding .git, .lake and .lun bookkeeping.
-/
import Lun.Spec
import Lun.Manifest
import Linen.System.Process
import Linen.Crypto.SecureRandom
import Linen.Data.Hex

namespace Lun.Local

open System (FilePath)
open Lean (Json)

/-- Bookkeeping directories never become local project source. -/
def excluded (name : String) : Bool := [".git", ".lake", ".lun"].contains name

/-- Copy only regular files/directories, at most 10,000 entries / 64 MiB.
    The work directory is skipped if it lies within the source folder. -/
private def copyTree (source dest workdir : FilePath) (timeoutMs : Nat) : IO Unit := do
  let mut pending := [(source, dest)]
  let mut count := 0
  let mut bytes := 0
  repeat
    let (origin, target) :: rest := pending | break
    pending := rest
    IO.FS.createDirAll target
    for entry in ← origin.readDir do
      if excluded entry.fileName || entry.path == workdir then continue
      count := count + 1
      unless count ≤ 10000 do throw (IO.userError "local folder has too many entries")
      let metadata ← entry.path.symlinkMetadata
      match metadata.type with
      | .dir => pending := (entry.path, target / entry.fileName) :: pending
      | .file =>
        bytes := bytes + metadata.byteSize.toNat
        unless bytes ≤ 64 * 1024 * 1024 do throw (IO.userError "local folder exceeds 64 MiB")
        let r ← System.Process.run "cp" #["-p", entry.path.toString, (target / entry.fileName).toString] timeoutMs
        unless r.ok do throw (IO.userError (r.describe "copying local source"))
      | _ => throw (IO.userError s!"local folder refuses symbolic links and special files: {entry.path}")

/-- Resolve Linen's relative local dependency against the original project,
    before moving its sources. The generated driver's root requirement uses it. -/
private def resolveDependency (source dest : FilePath) (path : String) : IO Unit := do
  let project := if path.isEmpty then source else source / path
  let target := if path.isEmpty then dest else dest / path
  let file := project / "lake-manifest.json"
  unless ← file.pathExists do return
  let manifest ← IO.ofExcept ((Manifest.parse (← IO.FS.readFile file)).mapError IO.userError)
  IO.ofExcept ((Manifest.check manifest true).mapError IO.userError)
  let json ← IO.ofExcept ((Json.parse (← IO.FS.readFile file)).mapError IO.userError)
  let packages ← IO.ofExcept ((json.getObjValAs? (Array Json) "packages").mapError IO.userError)
  let packages ← packages.mapM fun package => do
    if (package.getObjValAs? String "type").toOption != some "path" then return package
    let dir ← IO.ofExcept ((package.getObjValAs? String "dir").mapError IO.userError)
    let absolute ← IO.FS.realPath (project / dir)
    return package.setObjVal! "dir" (Json.str absolute.toString)
  IO.FS.writeFile (target / "lake-manifest.json") (json.setObjVal! "packages" (Json.arr packages)).pretty

/-- Freeze a working folder as a content-addressed Git source. Fixed commit
    metadata makes unchanged content reuse a build; edits produce a new id.
    Snapshot publication is serialized by the caller. -/
def snapshot (source : Source) (workdir : FilePath) (timeoutMs : Nat) : IO Source := do
  let some directory := source.directory | return source
  let root ← IO.FS.realPath directory
  unless ← root.isDir do throw (IO.userError "source.directory is not a folder")
  let workdir ← IO.FS.realPath workdir
  if root == workdir then throw (IO.userError "source.directory cannot be LUN_WORKDIR itself")
  let snapshots := workdir / "local"
  IO.FS.createDirAll snapshots
  let nonce := Data.Hex.encode (← Crypto.SecureRandom.randomBytes 16)
  let temp := snapshots / s!"snapshot-{nonce}"
  let git (args : Array String) : IO String := do
    let r ← System.Process.run "git" args timeoutMs (cwd := temp)
      (env := System.Process.hermeticGit ++
        #[("GIT_AUTHOR_DATE", some "2000-01-01T00:00:00Z"), ("GIT_COMMITTER_DATE", some "2000-01-01T00:00:00Z"),
          ("GIT_AUTHOR_NAME", some "lun"), ("GIT_COMMITTER_NAME", some "lun"),
          ("GIT_AUTHOR_EMAIL", some "local@lun"), ("GIT_COMMITTER_EMAIL", some "local@lun")])
    unless r.ok do throw (IO.userError (r.describe "snapshotting local source"))
    return r.stdout.trimAscii.toString
  try
    copyTree root temp workdir timeoutMs
    resolveDependency root temp source.path
    let _ ← git #["init", "--quiet", "--initial-branch=main", "--object-format=sha1"]
    let _ ← git #["-c", "core.autocrlf=false", "add", "--force", "--all"]
    let tree ← git #["write-tree"]
    let commit ← git #["-c", "commit.gpgsign=false", "commit-tree", tree, "-m", "local snapshot"]
    let _ ← git #["update-ref", "refs/heads/main", commit]
    let dest := snapshots / commit
    if ← dest.pathExists then IO.FS.removeDirAll temp else IO.FS.rename temp dest
    return { source with repo := { host := .local, segments := [], cloneUrl := "file://" ++ dest.toString },
                         branch := "main", commit, directory := none }
  finally
    if ← temp.pathExists then IO.FS.removeDirAll temp

end Lun.Local
