/-
  Lun.Build — builds: their ids, their lifecycle, and calling into them

  A build turns a `BuildSpec` into a checked, compiled driver:

  1. **fetch** the project at the commit (`Lun.Fetch`);
  2. **check** it may be built: a `lakefile`, a `lean-toolchain` and a
     committed `lake-manifest.json` that depends on linen only
     (`Lun.Manifest`);
  3. **generate** the driver around it (`Lun.Driver`), seeding linen's
     build from the package cache when the locked revision is there;
  4. **build** it with `lake build`: this type-checks every function against its
     declared signature, every graph against the functions, and compiles the
     `lun-driver` executable; every message is attributed to the function, graph
     or project it concerns (`Lun.Diagnostics`);
  5. **describe** it (`lun-driver describe`): the functions and each graph's
     structure, recorded in the status.

  Everything about a build lives under `{workdir}/builds/{id}/`: `status.json`
  (the single source of truth, rewritten atomically at every step),
  `spec.json` (the request without credentials), `build.log`, `src/` and
  `driver/`. Statuses survive a restart; a build a restart interrupted is
  marked failed on startup and is rebuilt when requested again.

  **Ids.** A build's id is the SHA-256 of a salt, the org the credentials
  belong to (or `public`) and the canonical request. The same request from the
  same org is the same build, so asking again returns it instead of
  rebuilding; the salt (`LUN_ID_SALT`, random per process if unset) makes ids
  unguessable from the request alone.

  **One build at a time.** Builds run on their own thread; fetching and
  checking start at once (a warrant expires within minutes), generating and
  compiling are serialised by a mutex: `lake` already uses every core, and
  linen's first build is heavy.
-/
import Lean.Data.Json
import Linen.Crypto.SHA256
import Linen.Crypto.SecureRandom
import Linen.Data.Hex
import Std.Sync.Mutex
import Lun.Spec
import Lun.Driver
import Lun.Manifest
import Lun.Diagnostics
import Lun.Process
import Lun.Fetch

namespace Lun

open Lean (Json ToJson toJson)
open System (FilePath)

-- ── Configuration ───────────────────────────────────────────────────────────

/-- lun's configuration (see `Main.lean` for the environment variables). -/
structure Config where
  workdir : FilePath
  liaisonUrl : Option String := none
  /-- A bearer token every request must carry, if set. -/
  token : Option String := none
  buildTimeoutMs : Nat := 3600 * 1000
  fetchTimeoutMs : Nat := 600 * 1000
  callTimeoutMs : Nat := 60 * 1000
  /-- Pre-built packages: `{cache}/linen/{rev}` is a linen checkout, built,
      at commit `rev`. -/
  packageCache : Option FilePath := none
  /-- Local mode: `file://` repositories and path dependencies (tests only). -/
  allowLocal : Bool := false
  salt : String

-- ── Statuses ────────────────────────────────────────────────────────────────

/-- Where a build is in its lifecycle. -/
inductive State where
  | queued | fetching | building | ready | failed
  deriving DecidableEq, Repr

def State.toString : State → String
  | .queued => "queued" | .fetching => "fetching" | .building => "building"
  | .ready => "ready" | .failed => "failed"

def State.ofString? : String → Option State
  | "queued" => some .queued | "fetching" => some .fetching | "building" => some .building
  | "ready" => some .ready | "failed" => some .failed | _ => none

/-- Still in progress. -/
def State.running (s : State) : Bool := s == .queued || s == .fetching || s == .building

/-- A build's status, as `GET /v0/builds/{id}` returns it. -/
structure Status where
  id : String
  state : State
  source : Json
  error : Option String := none
  diagnostics : Array Json := #[]
  /-- `lun-driver describe`'s answer, once ready: `{"functions": …, "graphs": …}`. -/
  description : Option Json := none

instance : ToJson Status where
  toJson s := Json.mkObj <|
    [ ("id", toJson s.id), ("state", toJson s.state.toString), ("source", s.source)
    , ("diagnostics", Json.arr s.diagnostics) ] ++
    (s.error.map fun e => [("error", toJson e)]).getD [] ++
    (match s.description with
     | some d => [("functions", (d.getObjVal? "functions").toOption.getD (Json.arr #[])),
                  ("graphs", (d.getObjVal? "graphs").toOption.getD (Json.arr #[]))]
     | none => [])

/-- Read a status back from its JSON. -/
def Status.ofJson (j : Json) : Except String Status := do
  let id ← j.getObjValAs? String "id"
  let some state := State.ofString? (← j.getObjValAs? String "state") | throw "unknown state"
  let source ← j.getObjVal? "source"
  let error := (j.getObjValAs? String "error").toOption
  let diagnostics := (j.getObjValAs? (Array Json) "diagnostics").toOption.getD #[]
  let description := match j.getObjVal? "functions", j.getObjVal? "graphs" with
    | .ok c, .ok d => some (Json.mkObj [("functions", c), ("graphs", d)])
    | _, _ => none
  return { id, state, source, error, diagnostics, description }

-- ── Paths ───────────────────────────────────────────────────────────────────

def buildDir (cfg : Config) (id : String) : FilePath := cfg.workdir / "builds" / id
def statusFile (cfg : Config) (id : String) : FilePath := buildDir cfg id / "status.json"
def logFile (cfg : Config) (id : String) : FilePath := buildDir cfg id / "build.log"
def srcDir (cfg : Config) (id : String) : FilePath := buildDir cfg id / "src"
def driverDir (cfg : Config) (id : String) : FilePath := buildDir cfg id / "driver"
def driverExe (cfg : Config) (id : String) : FilePath :=
  driverDir cfg id / ".lake" / "build" / "bin" / "lun-driver"

/-- A build id: 64 lowercase hex digits. -/
def validId (id : String) : Bool := id.length == 64 && id.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- The id of a request (see the module documentation). -/
def buildId (cfg : Config) (spec : BuildSpec) : IO String := do
  let scope := (spec.source.credentials.map (·.warrant.orgId.value)).getD "public"
  let input := s!"{cfg.salt}\n{scope}\n{spec.canonical.compress}"
  return Data.Hex.encode (← Crypto.SHA256.digest input.toUTF8)

/-- Write a status atomically (write, then rename). -/
def writeStatus (cfg : Config) (s : Status) : IO Unit := do
  let file := statusFile cfg s.id
  let tmp := file.withExtension "json.tmp"
  IO.FS.writeFile tmp (toJson s).pretty
  IO.FS.rename tmp file

/-- A build's status, if it exists. -/
def readStatus (cfg : Config) (id : String) : IO (Option Status) := do
  let file := statusFile cfg id
  unless ← file.pathExists do return none
  match Json.parse (← IO.FS.readFile file) >>= Status.ofJson with
  | .ok s => return some s
  | .error _ => return none

private def appendLog (cfg : Config) (id : String) (text : String) : IO Unit := do
  let h ← IO.FS.Handle.mk (logFile cfg id) .append
  h.putStr text
  h.putStr "\n"

-- ── Diagnostics ─────────────────────────────────────────────────────────────

/-- A diagnostic as a status reports it, with what it is about. -/
def diagnosticJson (spec : BuildSpec) (d : Diagnostics.Diagnostic) : Json :=
  let (scope, name, d) : String × Option String × Diagnostics.Diagnostic := match d.scope with
    | .function i => ("function", (spec.functions[i]?.map (·.name)), d)
    | .graph j => ("graph", (spec.graphs[j]?.map (·.name)),
        match spec.graphs[j]? with
        | some dg => d.inProgram (Driver.graphProgramStart spec.opens dg)
        | none => d)
    | .project => ("project", none, d)
    | .driver => ("driver", none, d)
    | .build => ("build", none, d)
  let base := match toJson d with
    | .obj kvs => kvs.toList
    | _ => []
  Json.mkObj <| [("scope", toJson scope)] ++ (name.map fun n => [("name", toJson n)]).getD [] ++
    base ++ ((Diagnostics.linenTooOldHint d).map fun h => [("hint", toJson h)]).getD []

/-- The diagnostics worth reporting: every error, and warnings about functions
    and graphs (not the project's or linen's own warnings). -/
def reportable (d : Diagnostics.Diagnostic) : Bool :=
  d.severity == "error" || match d.scope with
    | .function _ | .graph _ => true
    | _ => false

-- ── The builder ─────────────────────────────────────────────────────────────

/-- Running builds, and the lock that serialises them. -/
structure Builder where
  cfg : Config
  running : IO.Ref (List String)
  lock : Std.Mutex Unit

def Builder.new (cfg : Config) : IO Builder := do
  IO.FS.createDirAll (cfg.workdir / "builds")
  return { cfg, running := ← IO.mkRef [], lock := ← Std.Mutex.new () }

/-- Mark builds a restart interrupted as failed. -/
def Builder.recover (b : Builder) : IO Unit := do
  for entry in ← (b.cfg.workdir / "builds").readDir do
    if let some s ← readStatus b.cfg entry.fileName then
      if s.state.running then
        writeStatus b.cfg { s with state := .failed, error := some "interrupted by a restart" }

/-- Seed the driver's copy of linen from the package cache, when the project
    is locked to a revision the cache has built. -/
private def seedCache (b : Builder) (id : String) (m : Manifest.Manifest) : IO Unit := do
  let some cache := b.cfg.packageCache | return
  let some rev := Manifest.linenRev? m | return
  let cached := cache / "linen" / rev
  unless ← cached.pathExists do return
  let dest := driverDir b.cfg id / ".lake" / "packages"
  IO.FS.createDirAll dest
  let r ← Process.run "cp" #["-R", cached.toString, (dest / "linen").toString] b.cfg.fetchTimeoutMs
  appendLog b.cfg id s!"seeded linen {rev} from the package cache: {if r.ok then "ok" else r.describe "cp"}"

/-- What fetching and checking produce: the project, ready to build. -/
private structure Prepared where
  project : FilePath
  manifest : Manifest.Manifest
  toolchain : String

/-- Steps 1–2, fetch and check. Not under the build lock: a warrant is
    short-lived (the app mints them for 300 s), so a queued build fetches with
    it right away rather than after the builds ahead of it. -/
private def Builder.prepare (b : Builder) (spec : BuildSpec) (status : Status) : IO Prepared := do
  let cfg := b.cfg
  let id := status.id
  writeStatus cfg { status with state := .fetching }
  let src := srcDir cfg id
  if ← src.pathExists then IO.FS.removeDirAll src
  Fetch.fetch { liaisonUrl := cfg.liaisonUrl, timeoutMs := cfg.fetchTimeoutMs } spec.source src
  appendLog cfg id s!"fetched {spec.source.repo.cloneUrl} at {spec.source.commit}"
  let project := if spec.source.path.isEmpty then src else src / spec.source.path
  unless (← (project / "lakefile.lean").pathExists) || (← (project / "lakefile.toml").pathExists) do
    throw (IO.userError s!"no lakefile.lean or lakefile.toml in '{spec.source.path}'")
  let toolchainFile := project / "lean-toolchain"
  unless ← toolchainFile.pathExists do throw (IO.userError "the project has no lean-toolchain")
  let manifestFile := project / "lake-manifest.json"
  unless ← manifestFile.pathExists do
    throw (IO.userError "the project has no committed lake-manifest.json")
  let manifest ← IO.ofExcept (Manifest.parse (← IO.FS.readFile manifestFile) |>.mapError IO.userError)
  IO.ofExcept (Manifest.check manifest cfg.allowLocal |>.mapError IO.userError)
  writeStatus cfg { status with state := .queued }
  return { project, manifest, toolchain := ← IO.FS.readFile toolchainFile }

/-- Steps 3–5, generate, build and describe, under the build lock. -/
private def Builder.compile (b : Builder) (spec : BuildSpec) (status : Status) (p : Prepared) :
    IO Unit := do
  let cfg := b.cfg
  let id := status.id
  let set (s : Status) := writeStatus cfg s
  -- 3. generate
  set { status with state := .building }
  let driver := driverDir cfg id
  if ← driver.pathExists then IO.FS.removeDirAll driver
  let files := Driver.files
    { spec, projectDir := ← IO.FS.realPath p.project, packageName := p.manifest.name
      toolchain := p.toolchain }
  for (path, contents) in files do
    let file := driver / path
    if let some dir := file.parent then IO.FS.createDirAll dir
    IO.FS.writeFile file contents
  seedCache b id p.manifest
  -- 4. build. Lake clones the project's dependencies (linen) with git.
  let r ← Process.run "lake" #["build"] cfg.buildTimeoutMs (cwd := driver) (env := Process.hermeticGit)
  appendLog cfg id r.stdout
  appendLog cfg id r.stderr
  unless r.ok do
    let diags := (Diagnostics.parse (r.stdout ++ "\n" ++ r.stderr)).filter reportable
    let error := match r.exitCode with
      | none => "the build timed out"
      | some _ => if diags.isEmpty then r.describe "lake build" else "the build failed"
    set { status with
          state := .failed
          diagnostics := (diags.map (diagnosticJson spec)).toArray
          error := some error }
    return
  -- 5. describe
  let d ← Process.run (driverExe cfg id).toString #["describe"] cfg.callTimeoutMs
  unless d.ok do throw (IO.userError (d.describe "lun-driver describe"))
  let description ← IO.ofExcept (Json.parse d.stdout |>.mapError IO.userError)
  let warnings := (Diagnostics.parse r.stdout).filter reportable
  set { status with
        state := .ready
        description := some description
        diagnostics := (warnings.map (diagnosticJson spec)).toArray }

/-- Record a failure in the status. -/
private def Builder.fail (b : Builder) (status : Status) (e : IO.Error) : IO Unit := do
  appendLog b.cfg status.id s!"failed: {e}"
  writeStatus b.cfg { status with state := .failed, error := some (toString e) }

/-- Compile, recording a failure in the status. -/
private def Builder.attempt (b : Builder) (spec : BuildSpec) (status : Status) (p : Prepared) :
    IO Unit := do
  try b.compile spec status p catch e => b.fail status e

/-- Run a build to completion: fetch at once, then compile one at a time. -/
private def Builder.run (b : Builder) (spec : BuildSpec) (status : Status) : IO Unit := do
  try
    match ← (b.prepare spec status).toBaseIO with
    | .error e => b.fail status e
    | .ok p =>
      b.lock.atomically (m := IO) (monadLift (b.attempt spec status p) : Std.AtomicT Unit IO Unit)
  finally
    b.running.modify (·.erase status.id)

/-- Submit a request: the existing build if there is one (ready or in
    progress), otherwise a new one, started in the background. -/
def Builder.submit (b : Builder) (spec : BuildSpec) : IO Status := do
  let id ← buildId b.cfg spec
  let existing ← readStatus b.cfg id
  if (← b.running.get).contains id then
    if let some s := existing then return s
  if let some s := existing then
    if s.state == .ready then return s
  IO.FS.createDirAll (buildDir b.cfg id)
  IO.FS.writeFile (buildDir b.cfg id / "spec.json") spec.canonical.pretty
  let status : Status := { id, state := .queued, source := (spec.canonical.getObjVal? "source").toOption.getD Json.null }
  writeStatus b.cfg status
  b.running.modify (id :: ·)
  let _ ← IO.asTask (prio := .dedicated) (b.run spec status)
  return status

-- ── Calling a built driver ──────────────────────────────────────────────────

/-- What a call into a driver answered: an HTTP status and a JSON body. -/
structure Answer where
  status : Nat
  body : Json

private def errorAnswer (status : Nat) (msg : String) : Answer :=
  { status, body := Json.mkObj [("error", toJson msg)] }

/-- Call a function (`kind = "function"`), a graph (`kind = "graph"`) or a session of a
    graph (`kind = "session-start"`/`"session-update"`, `Lun.Session`) of a
    ready build with a JSON request body. The driver's traces (stderr) come
    back as `log`. -/
def Builder.call (b : Builder) (id kind name : String) (request : String) : IO Answer := do
  let some s ← readStatus b.cfg id | return errorAnswer 404 "no such build"
  unless s.state == .ready do
    return errorAnswer 409 s!"the build is {s.state.toString}, not ready"
  let listed := s.description.bind fun d =>
    (d.getObjValAs? (Array Json) (if kind == "function" then "functions" else "graphs")).toOption.map fun xs =>
      xs.any fun x => (x.getObjValAs? String "name").toOption == some name
  unless listed == some true do
    return errorAnswer 404 s!"the build has no {if kind == "function" then "function" else "graph"} named '{name}'"
  let r ← Process.run (driverExe b.cfg id).toString #[kind, name] b.cfg.callTimeoutMs (input := request)
  let status := match r.exitCode with
    | some 0 => 200 | some 1 => 400 | none => 504 | some _ => 502
  if status == 504 then return errorAnswer 504 s!"the {kind} did not answer within the time limit"
  match Json.parse r.stdout with
  | .ok (.obj kvs) =>
    let log := r.stderr.trimAscii.toString
    let body := if log.isEmpty then Json.obj kvs else Json.obj (kvs.insert "log" (toJson log))
    return { status, body }
  | _ => return errorAnswer 502 (r.describe s!"the {kind}")

end Lun
