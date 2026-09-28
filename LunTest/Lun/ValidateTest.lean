/-
  Tests for `Lun.Validate`: every grammar accepts what it should and refuses
  what would be dangerous downstream (a flag to git, a path escape, a
  non-identifier in generated Lean).
-/
import Lun.Validate

open Lun.Validate

namespace LunTests.Validate

-- ── Names ───────────────────────────────────────────────────────────────────

#guard functionName "math.double"
#guard functionName "_x.y_1"
#guard !functionName ""
#guard !functionName "math..double"
#guard !functionName "1x"
#guard !functionName "a-b"
#guard !functionName "a b"
#guard !functionName "«a»"
#guard !functionName ("a" ++ "".pushn 'b' 200)

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

-- (Branch names and repository URLs are linen's `System.Git.Remote`, tested there.)

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

end LunTests.Validate
