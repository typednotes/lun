/-
  Tests for `Lun.Process`: output capture, stdin, exit codes and the
  deadline.
-/
import Lun.Process

open Lun.Process

namespace LunTests.Process

/-- info: (some 0, "hello\n", "") -/
#guard_msgs in
#eval show IO _ from do
  let r ← run "echo" #["hello"] 5000
  pure (r.exitCode, r.stdout, r.stderr)

/-- info: (some 0, "from stdin") -/
#guard_msgs in
#eval show IO _ from do
  let r ← run "cat" #[] 5000 (input := some "from stdin")
  pure (r.exitCode, r.stdout)

/-- info: (some 3, "oops\n") -/
#guard_msgs in
#eval show IO _ from do
  let r ← run "sh" #["-c", "echo oops >&2; exit 3"] 5000
  pure (r.exitCode, r.stderr)

-- A command past its deadline is killed, and says so.
/-- info: (none, true, "sleeping timed out") -/
#guard_msgs in
#eval show IO _ from do
  let start ← IO.monoMsNow
  let r ← run "sleep" #["30"] 300
  pure (r.exitCode, decide ((← IO.monoMsNow) - start < 5000), r.describe "sleeping")

-- The hermetic git environment ignores the host's configuration.
#guard hermeticGit.contains ("GIT_CONFIG_GLOBAL", some "/dev/null")

end LunTests.Process
