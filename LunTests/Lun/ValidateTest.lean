/-
  Tests for `Lun.Validate`: every grammar accepts what it should and refuses
  what would be dangerous downstream (a flag to git, a path escape, a
  non-identifier in generated Lean, a URL with userinfo).
-/
import Lun.Validate

open Lun.Validate

namespace LunTests.Validate

-- ── Names ───────────────────────────────────────────────────────────────────

#guard cellName "math.double"
#guard cellName "_x.y_1"
#guard !cellName ""
#guard !cellName "math..double"
#guard !cellName "1x"
#guard !cellName "a-b"
#guard !cellName "a b"
#guard !cellName "«a»"
#guard !cellName ("a" ++ "".pushn 'b' 200)

#guard moduleName "MyProject.Math"
#guard !moduleName "MyProject/Math"

#guard declName "Fixture.double"
#guard declName "List.find?" && declName "get!" && declName "x'"
#guard !declName "?x"
#guard !declName "a.(b)"

-- ── Git ─────────────────────────────────────────────────────────────────────

#guard commit "dc19b371d09f409810678d8b35dbb381afecf272"
#guard commit ("".pushn 'a' 64)
#guard !commit "dc19b37"                                   -- abbreviated
#guard !commit "DC19B371D09F409810678D8B35DBB381AFECF272" -- uppercase
#guard !commit ("".pushn 'g' 40)

#guard branch "main" && branch "feature/x-1" && branch "release-1.2"
#guard !branch ""
#guard !branch "-rf"                 -- would be a flag to git
#guard !branch "a..b" && !branch "a b" && !branch "a~1" && !branch "a:b"
#guard !branch "a//b" && !branch "/a" && !branch "a/" && !branch "a."
#guard !branch ".hidden" && !branch "a/.b" && !branch "x.lock" && !branch "@" && !branch "a@{1}"

-- ── Paths ───────────────────────────────────────────────────────────────────

#guard projectPath "" && projectPath "lean" && projectPath "a/b-c/d_e.f"
#guard !projectPath "/abs" && !projectPath "../up" && !projectPath "a/../b"
#guard !projectPath "a/./b" && !projectPath "a//b" && !projectPath "a/b/"

-- ── Lean text ───────────────────────────────────────────────────────────────

#guard leanText "Nat → Eff [] Nat" (multiline := false)
#guard !leanText "Nat\n→ Nat" (multiline := false)
#guard leanText "do\n\tlet x ← input \"x\" Nat\n  pure ()" (multiline := true)
#guard !leanText "   " (multiline := true)
#guard !leanText (String.singleton (Char.ofNat 0)) (multiline := true)

-- ── Repository URLs ─────────────────────────────────────────────────────────

#guard (repo "https://github.com/owner/repo").toOption ==
  some { host := .github, segments := ["owner", "repo"], cloneUrl := "https://github.com/owner/repo.git" }
#guard (repo "https://github.com/owner/repo.git/").toOption.map (·.cloneUrl) ==
  some "https://github.com/owner/repo.git"
#guard (repo "https://GitLab.com/g/sub/p").toOption.map (·.host) == some .gitlab
#guard (repo "https://gitlab.com/g/sub/p").toOption.map (·.segments) == some ["g", "sub", "p"]
#guard (repo "https://git.example.org/x").toOption.map (·.host) == some (.other "git.example.org")
#guard (repo "http://github.com/o/r").toOption.isNone                -- not https
#guard (repo "https://user:pw@github.com/o/r").toOption.isNone       -- userinfo
#guard (repo "https://github.com:22/o/r").toOption.isNone            -- port
#guard (repo "https://github.com/o/r?x=1").toOption.isNone           -- query
#guard (repo "https://github.com/o/r/tree/main").toOption.isNone     -- not OWNER/REPO
#guard (repo "https://example.org/a/../b").toOption.isNone           -- dot segment
#guard (repo "https://github.com").toOption.isNone
#guard (repo "file:///tmp/x").toOption.isNone                        -- local mode only
#guard (repo "file:///tmp/x" (allowLocal := true)).toOption.map (·.host) == some .local
#guard (repo "file://relative/x" (allowLocal := true)).toOption.isNone

#guard Host.github.provider? == some "github"
#guard (Host.other "x").provider? == none

end LunTests.Validate
