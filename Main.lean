import Lun
import Linen.Network.WebApp.Server

/-- Read a number of seconds from the environment, in milliseconds. -/
def secondsEnv (name : String) (default : Nat) : IO Nat := do
  match ← IO.getEnv name with
  | none => return default * 1000
  | some v => match v.toNat? with
    | some n => return n * 1000
    | none => throw (IO.userError s!"{name} must be a number of seconds")

/-- Entry point. Configuration, from the environment:

    - `LUN_PORT` — default `8080`;
    - `LUN_WORKDIR` — where builds live, default `/var/lib/lun`;
    - `LUN_TOKEN` — if set, the bearer token every API call must carry;
    - `LUN_LIAISON_URL` — liaison's base URL, needed for private repositories;
    - `LUN_BUILD_TIMEOUT`, `LUN_FETCH_TIMEOUT`, `LUN_CALL_TIMEOUT` —
      seconds; defaults `3600`, `600`, `60`;
    - `LUN_PACKAGE_CACHE` — pre-built packages (`{cache}/linen/{rev}`);
    - `LUN_ID_SALT` — salt for build ids; random per process if unset (ids
      then change across restarts, and builds are redone);
    - `LUN_ALLOW_LOCAL=1` — local mode: `file://` repositories and path
      dependencies. For tests; never in production. -/
def main : IO Unit := do
  let port : UInt16 := match (← IO.getEnv "LUN_PORT").bind String.toNat? with
    | some p => p.toUInt16
    | none => 8080
  let workdir := (← IO.getEnv "LUN_WORKDIR").getD "/var/lib/lun"
  let salt ← match ← IO.getEnv "LUN_ID_SALT" with
    | some s => pure s
    | none => Data.Hex.encode <$> Crypto.SecureRandom.randomBytes 32
  let allowLocal := (← IO.getEnv "LUN_ALLOW_LOCAL") == some "1"
  let liaisonSdkPath ← if allowLocal then do
    pure ((← IO.getEnv "LUN_LIAISON_SDK_PATH").map System.FilePath.mk)
    else pure none
  let cfg : Lun.Config :=
    { workdir := workdir
      liaisonUrl := ← IO.getEnv "LUN_LIAISON_URL"
      token := (← IO.getEnv "LUN_TOKEN").filter (!·.isEmpty)
      buildTimeoutMs := ← secondsEnv "LUN_BUILD_TIMEOUT" 3600
      fetchTimeoutMs := ← secondsEnv "LUN_FETCH_TIMEOUT" 600
      callTimeoutMs := ← secondsEnv "LUN_CALL_TIMEOUT" 60
      packageCache := (← IO.getEnv "LUN_PACKAGE_CACHE").map System.FilePath.mk
      allowLocal
      liaisonSdkPath
      salt }
  let builder ← Lun.Builder.new cfg
  builder.recover
  if allowLocal then IO.eprintln "lun: LOCAL MODE — file:// repositories and path dependencies accepted"
  if cfg.token.isNone then IO.eprintln "lun: LUN_TOKEN is not set — the API is unauthenticated"
  IO.println s!"lun listening on :{port}"
  Network.WebApp.Server.run port (Lun.application builder (← Lun.Sessions.new))
