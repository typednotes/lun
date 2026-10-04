import Lun
import Linen.Network.WebApp.Server

/-- Read a number of seconds from the environment, in milliseconds. -/
def secondsEnv (name : String) (default : Nat) : IO Nat := do
  match ← IO.getEnv name with
  | none => return default * 1000
  | some v => match v.toNat? with
    | some n => return n * 1000
    | none => throw (IO.userError s!"{name} must be a number of seconds")

/-- `lun serve` (default) runs HTTP; `lun cli` serves JSON lines over standard
    streams. Configuration, from the environment:

    - `LUN_PORT` — default `8080`;
    - `LUN_WORKDIR` — where builds live, default `/var/lib/lun` for HTTP,
      `.lun` for CLI;
    - `LUN_TOKEN` — if set, the bearer token every API call must carry;
    - `LUN_LIAISON_URL` — liaison's base URL, needed for private repositories;
    - `LUN_BUILD_TIMEOUT`, `LUN_FETCH_TIMEOUT`, `LUN_CALL_TIMEOUT` —
      seconds; defaults `3600`, `600`, `60`;
    - `LUN_PACKAGE_CACHE` — pre-built packages (`{cache}/linen/{rev}`);
    - `LUN_WORKERS` — maximum loaded driver workers, default 4, range 1–16;
    - `LUN_ID_SALT` — salt for build ids; random per process if unset (ids
      then change across HTTP restarts; CLI persists its generated salt);
    - `LUN_ALLOW_LOCAL=1` — local mode: working folders, `file://` repositories
      and path dependencies. Enabled automatically by CLI. -/
def main (args : List String) : IO UInt32 := do
  if args == ["--help"] || args == ["-h"] then
    IO.println "Usage: lun [serve | cli]\n\nserve (default): HTTP REST service, configured by LUN_* environment variables.\ncli: local JSON-lines requests on stdin, replies on stdout, diagnostics on stderr.\n     Builds wait by default; folders and file:// repositories are accepted.\n     LUN_WORKDIR defaults to .lun; its generated id salt persists across runs."
    return 0
  unless args.isEmpty || args == ["serve"] || args == ["cli"] do
    IO.eprintln "Usage: lun [serve | cli] (see --help)"
    return 2
  let cli := args == ["cli"]
  let port : UInt16 := match (← IO.getEnv "LUN_PORT").bind String.toNat? with
    | some p => p.toUInt16
    | none => 8080
  let workdir : System.FilePath := (← IO.getEnv "LUN_WORKDIR").getD (if cli then ".lun" else "/var/lib/lun")
  IO.FS.createDirAll workdir
  let salt ← match ← IO.getEnv "LUN_ID_SALT" with
    | some s => pure s
    | none =>
      if cli then
        let file := workdir / "id-salt"
        if ← file.pathExists then IO.FS.readFile file else do
          let salt := Data.Hex.encode (← Crypto.SecureRandom.randomBytes 32)
          IO.FS.writeFile file salt
          pure salt
      else Data.Hex.encode <$> Crypto.SecureRandom.randomBytes 32
  let allowLocal := cli || (← IO.getEnv "LUN_ALLOW_LOCAL") == some "1"
  let liaisonSdkPath ← if allowLocal then do
    pure ((← IO.getEnv "LUN_LIAISON_SDK_PATH").map System.FilePath.mk)
    else pure none
  let workerCount ← match ← IO.getEnv "LUN_WORKERS" with
    | none => pure 4
    | some value => match value.toNat? with
      | some n => pure n
      | none => throw (IO.userError "LUN_WORKERS must be an integer from 1 to 16")
  let workerCapacity ← IO.ofExcept ((Lun.WorkerCache.Capacity.check workerCount).mapError IO.userError)
  let cfg : Lun.Config :=
    { workdir := workdir
      liaisonUrl := ← IO.getEnv "LUN_LIAISON_URL"
      token := (← IO.getEnv "LUN_TOKEN").filter (!·.isEmpty)
      buildTimeoutMs := ← secondsEnv "LUN_BUILD_TIMEOUT" 3600
      fetchTimeoutMs := ← secondsEnv "LUN_FETCH_TIMEOUT" 600
      callTimeoutMs := ← secondsEnv "LUN_CALL_TIMEOUT" 60
      workerCapacity
      packageCache := (← IO.getEnv "LUN_PACKAGE_CACHE").map System.FilePath.mk
      allowLocal
      liaisonSdkPath
      salt }
  let builder ← Lun.Builder.new cfg
  builder.recover
  if allowLocal then IO.eprintln "lun: LOCAL MODE — folders, file:// repositories and path dependencies accepted"
  try
    if cli then return ← Lun.Cli.run builder
    if cfg.token.isNone then IO.eprintln "lun: LUN_TOKEN is not set — the API is unauthenticated"
    IO.eprintln s!"lun listening on :{port}"
    Network.WebApp.Server.run port (Lun.application builder)
    return 0
  finally builder.workers.close
