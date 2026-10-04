/-
  Lun.Validate — the syntax of everything a build request names

  Every string a request carries ends up somewhere load-bearing: a git
  command line, a file path under the build directory, a Lean identifier in a
  generated module, a URL sent to liaison. Each is checked here against a
  deliberately narrow grammar, so that downstream code can treat it as data
  of that shape and nothing else. All checks are pure and total. Commit ids,
  branch names and repository URLs are linen's (`System.GitFn.CommitSha`,
  `System.Git.Remote`), which lode uses too: lode writes the repositories lun
  reads, so both must agree on them.
-/
import Linen.System.GitFn.Descriptor
import Linen.System.Git.Remote

namespace Lun.Validate

-- ── Identifiers ─────────────────────────────────────────────────────────────

/-- `[A-Za-z_]` (ASCII: `Char.isAlpha` is ASCII-only). -/
def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'

/-- `[A-Za-z0-9_]`. -/
def isIdentChar (c : Char) : Bool := c.isAlphanum || c == '_'

/-- One identifier component: `[A-Za-z_][A-Za-z0-9_]*`. -/
def identComponent (s : String) : Bool :=
  match s.toList with
  | c :: cs => isIdentStart c && cs.all isIdentChar
  | [] => false

/-- One component of a Lean declaration name: an identifier component that
    may also contain (after its first character) `'`, `!` and `?`, as in
    `foo'`, `get!`, `find?`. -/
def declComponent (s : String) : Bool :=
  match s.toList with
  | c :: cs => isIdentStart c && cs.all fun c => isIdentChar c || c == '\'' || c == '!' || c == '?'
  | [] => false

/-- A dotted name whose every component satisfies `component`, at most
    `maxLen` characters. -/
def dotted (component : String → Bool) (maxLen : Nat := 256) (s : String) : Bool :=
  s.length ≤ maxLen && (s.splitOn ".").all component

/-- A function or graph name: dotted identifiers, e.g. `math.double`. Also a Lean
    name in the generated driver, and what a graph program calls the function by. -/
def functionName (s : String) : Bool := dotted identComponent 128 s

/-- A Lean module name, e.g. `MyProject.Math`. -/
def moduleName (s : String) : Bool := dotted identComponent 256 s

/-- A fully qualified Lean declaration name, e.g. `MyProject.Math.double`. -/
def declName (s : String) : Bool := dotted declComponent 256 s

-- ── Git ─────────────────────────────────────────────────────────────────────

/-- A commit id: a full SHA-1 (40) or SHA-256 (64) object name in lowercase
    hex (`System.GitFn.CommitSha.isValid`). Abbreviations are refused — a
    build is pinned to exactly one commit. -/
def commit (s : String) : Bool := System.GitFn.CommitSha.isValid s

-- ── Paths ───────────────────────────────────────────────────────────────────

/-- A project directory inside the repository: empty (the root) or relative
    components separated by `/`, each a plain segment (`[A-Za-z0-9._-]+`, not
    `.` or `..`: `System.Git.Repository.isSegment`). Never absolute, never
    escaping the checkout. -/
def projectPath (s : String) : Bool :=
  s.isEmpty || (s.length ≤ 512 && (s.splitOn "/").all System.Git.Repository.isSegment)

/-- An explicit local folder: absolute, without control characters or dot
    segments. Spaces and Unicode are permitted; it is never shell text. -/
def localDirectory (s : String) : Bool :=
  s.startsWith "/" && s.length ≤ 4096 && s.all (fun c => c.toNat ≥ 0x20 && c.toNat != 0x7f) &&
    ((s.splitOn "/").drop 1).all (fun part => !part.isEmpty && part != "." && part != "..")

-- ── Embedded Lean text ──────────────────────────────────────────────────────

/-- Lean source a request embeds (a signature, a graph program): no NUL and no
    control characters other than newline and tab. The driver parses it as
    exactly one term, so this is hygiene, not the safety boundary. -/
def leanText (s : String) (multiline : Bool) (maxLen : Nat := 65536) : Bool :=
  !s.trimAscii.isEmpty && s.length ≤ maxLen &&
    s.all fun c => c.toNat ≥ 0x20 || c == '\t' || (multiline && c == '\n')

end Lun.Validate
