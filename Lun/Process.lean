/-
  Lun.Process — run a command to completion, with a deadline

  Everything lun runs (`git`, `tar`, `lake`, a driver) goes through `run`:
  stdout and stderr captured, optional stdin, and a timeout after which the
  whole process group is killed (the child is started in its own session, so
  `lake`'s `lean` workers go with it).
-/

namespace Lun.Process

/-- How a command ended. -/
structure Result where
  /-- The exit code, or `none` if it was killed at the deadline. -/
  exitCode : Option UInt32
  stdout : String
  stderr : String

/-- It exited with `0`. -/
def Result.ok (r : Result) : Bool := r.exitCode == some 0

/-- Write the input, then drop the handle, which closes the child's stdin. -/
private def feed (h : IO.FS.Handle) (input : Option String) : IO Unit := do
  if let some s := input then
    -- A child that exits without reading closes the pipe; that is its answer.
    try h.putStr s; h.flush catch _ => pure ()

/-- Run `cmd args` in `cwd`, feeding `input` on stdin, killing it (and its
    process group) after `timeoutMs` milliseconds. -/
def run (cmd : String) (args : Array String) (timeoutMs : Nat)
    (cwd : Option System.FilePath := none) (env : Array (String × Option String) := #[])
    (input : Option String := none) : IO Result := do
  let child ← IO.Process.spawn
    { cmd, args, cwd, env, setsid := true
      stdin := .piped, stdout := .piped, stderr := .piped }
  let out ← IO.asTask child.stdout.readToEnd .dedicated
  let err ← IO.asTask child.stderr.readToEnd .dedicated
  let (stdin, child) ← child.takeStdin
  feed stdin input
  let deadline := (← IO.monoMsNow) + timeoutMs
  let mut code : Option UInt32 := none
  repeat
    match ← child.tryWait with
    | some c => code := some c; break
    | none =>
      if (← IO.monoMsNow) ≥ deadline then
        child.kill
        let _ ← child.wait
        break
      IO.sleep 20
  let stdout ← IO.ofExcept (← IO.wait out)
  let stderr ← IO.ofExcept (← IO.wait err)
  return { exitCode := code, stdout, stderr }

/-- The environment `git` and `lake` run with: the host's global and system
    git configuration ignored (a `url.insteadOf` rewrite, a credential helper
    or commit signing there would change what is fetched or make a build
    hang), and git never prompting. -/
def hermeticGit : Array (String × Option String) :=
  #[("GIT_CONFIG_GLOBAL", some "/dev/null"), ("GIT_CONFIG_NOSYSTEM", some "1"),
    ("GIT_TERMINAL_PROMPT", some "0"), ("GIT_ASKPASS", some "true")]

/-- A one-line account of a failed command, for error messages and logs. -/
def Result.describe (r : Result) (what : String) : String :=
  let reason := match r.exitCode with
    | none => "timed out"
    | some c => s!"exited with {c}"
  let detail := (if r.stderr.trimAscii.isEmpty then r.stdout else r.stderr).trimAscii.toString
  s!"{what} {reason}" ++ (if detail.isEmpty then "" else s!": {detail}")

end Lun.Process
