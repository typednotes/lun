/-
  Lun.Validate — the syntax of everything a build request names

  Every string a request carries ends up somewhere load-bearing: a git
  command line, a file path under the build directory, a Lean identifier in a
  generated module, a URL sent to liaison. Each is checked here against a
  deliberately narrow grammar, so that downstream code can treat it as data
  of that shape and nothing else. All checks are pure and total.
-/

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
    hex. Abbreviations are refused — a build is pinned to exactly one commit. -/
def commit (s : String) : Bool :=
  (s.length == 40 || s.length == 64) && s.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- A branch name, per `git check-ref-format --branch`: no control characters,
    space or `~^:?*[\`; no `..`, `@{`, `//`; no component starting with `.` or
    ending in `.lock`; not starting with `-` or `/`, not ending with `/` or
    `.`, not `@`. -/
def branch (s : String) : Bool :=
  let forbidden (c : Char) := c.toNat < 0x20 || c.toNat == 0x7f || " ~^:?*[\\".contains c
  !s.isEmpty && s.length ≤ 255 && s != "@" && !s.any forbidden &&
    (s.splitOn "..").length == 1 &&
    (s.splitOn "@{").length == 1 && (s.splitOn "//").length == 1 &&
    !s.startsWith "-" && !s.startsWith "/" && !s.endsWith "/" && !s.endsWith "." &&
    (s.splitOn "/").all fun comp => !comp.isEmpty && !comp.startsWith "." && !comp.endsWith ".lock"

-- ── Paths ───────────────────────────────────────────────────────────────────

/-- One path component: `[A-Za-z0-9._-]+`, not `.` or `..`. -/
def pathComponent (s : String) : Bool :=
  !s.isEmpty && s != "." && s != ".." &&
    s.all fun c => c.isAlphanum || c == '.' || c == '_' || c == '-'

/-- A project directory inside the repository: empty (the root) or relative
    components separated by `/`. Never absolute, never escaping the checkout. -/
def projectPath (s : String) : Bool :=
  s.isEmpty || (s.length ≤ 512 && (s.splitOn "/").all pathComponent)

-- ── Embedded Lean text ──────────────────────────────────────────────────────

/-- Lean source a request embeds (a signature, a graph program): no NUL and no
    control characters other than newline and tab. The driver parses it as
    exactly one term, so this is hygiene, not the safety boundary. -/
def leanText (s : String) (multiline : Bool) (maxLen : Nat := 65536) : Bool :=
  !s.trimAscii.isEmpty && s.length ≤ maxLen &&
    s.all fun c => c.toNat ≥ 0x20 || c == '\t' || (multiline && c == '\n')

-- ── Repository URLs ─────────────────────────────────────────────────────────

/-- Where a repository is hosted, which decides how it can be fetched. -/
inductive Host where
  /-- `github.com`: credentials go through liaison's `github` connection. -/
  | github
  /-- `gitlab.com`: credentials go through liaison's `gitlab` connection. -/
  | gitlab
  /-- Any other `https` host: public repositories only. -/
  | other (host : String)
  /-- A local repository (`file://`), accepted only in local mode (tests). -/
  | local
  deriving DecidableEq, Repr

/-- A parsed repository URL. -/
structure Repo where
  host : Host
  /-- The path segments on the host (`owner/repo`, `group/…/project`), or the
      absolute path of a local repository. -/
  segments : List String
  /-- The canonical URL to clone. -/
  cloneUrl : String
  deriving DecidableEq, Repr

/-- The provider name liaison knows the host's connections by. -/
def Host.provider? : Host → Option String
  | .github => some "github"
  | .gitlab => some "gitlab"
  | _ => none

/-- Parse a repository URL, the way it is written for `git clone`:
    `https://github.com/owner/repo(.git)`, `https://gitlab.com/group/…/project(.git)`,
    or another `https` host. No userinfo, port, query or fragment. `file:///abs/path`
    only when `allowLocal`. -/
def repo (url : String) (allowLocal : Bool := false) : Except String Repo := do
  if url.length > 1024 then throw "the repository URL is too long"
  let strip (s : String) : String :=
    let s := if s.endsWith "/" then (s.dropEnd 1).toString else s
    if s.endsWith ".git" then (s.dropEnd 4).toString else s
  if url.startsWith "file://" then
    unless allowLocal do throw "file:// repositories are only accepted in local mode"
    let path := (url.drop 7).toString
    let segs := (path.splitOn "/").drop 1
    unless path.startsWith "/" && segs.all pathComponent do
      throw "a file:// URL must name an absolute path of plain components"
    return { host := .local, segments := segs, cloneUrl := url }
  unless url.startsWith "https://" do throw "the repository URL must be https://"
  let rest := strip (url.drop 8).toString
  match rest.splitOn "/" with
  | [] | [_] => throw "the repository URL names no repository"
  | hostName :: segs =>
    unless !hostName.isEmpty && hostName.all (fun c => c.isAlphanum || c == '.' || c == '-') do
      throw "the repository host must be a plain DNS name (no userinfo or port)"
    unless segs.all pathComponent do
      throw "the repository path must be plain components (no query, fragment or dot segments)"
    let host : Host := match hostName.toLower with
      | "github.com" => .github
      | "gitlab.com" => .gitlab
      | h => .other h
    if host == .github && segs.length != 2 then
      throw "a GitHub repository URL is https://github.com/OWNER/REPO"
    let cloneUrl := s!"https://{hostName.toLower}/{"/".intercalate segs}.git"
    return { host, segments := segs, cloneUrl }

end Lun.Validate
