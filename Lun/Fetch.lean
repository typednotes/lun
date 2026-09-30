/-
  Lun.Fetch — get the project at exactly the requested commit

  Two ways, one guarantee: the checkout is the tree of `commit`, and `commit`
  is on `branch` (an ancestor of its head, or the head itself).

  - **Public repository** (no credentials): `git`. A blobless clone of the
    branch (`--filter=blob:none`: the whole commit graph, no file contents
    yet), `git merge-base --is-ancestor` for the branch check, then a detached
    checkout of the commit, which fetches just its blobs.
  - **Private repository** on github.com or gitlab.com: lun never holds the
    credential, and liaison only relays calls under the connection's API
    `base_url` — so not `git`, but each host's REST API, through liaison:

    | | branch check | tree |
    |---|---|---|
    | GitHub | `GET /repos/{o}/{r}/compare/{branch}...{commit}`: `status` is `behind` or `identical` | `GET /repos/{o}/{r}/tarball/{commit}` answers `302` to a short-lived signed `codeload.github.com` URL, which lun then downloads directly (it carries its own token; nothing else is sent) |
    | GitLab | `GET /projects/{path}/repository/merge_base?refs[]={branch}&refs[]={commit}` is `commit` | `GET /projects/{path}/repository/archive.tar.gz?sha={commit}`, relayed by liaison |

    The archive is unpacked with `tar --strip-components=1`. Submodules are
    not fetched on either path.
-/
import Lean.Data.Json
import Linen.Network.HTTP.Simple
import Linen.Network.HTTP.Types.URI
import Linen.Data.Time.Clock
import Linen.Data.Base64
import Lun.Spec
import Linen.System.Process

namespace Lun.Fetch

open Lean (Json)
open Network.HTTP.Client (Request Response)
open Network.HTTP.Types

/-- What fetching needs from the configuration. -/
structure Context where
  /-- liaison's base URL, e.g. `http://liaison:8080`; required for private
      repositories. -/
  liaisonUrl : Option String
  timeoutMs : Nat

-- ── URLs ────────────────────────────────────────────────────────────────────

/-- Percent-encode everything but RFC 3986's unreserved characters
    (linen's `Network.HTTP.Types.urlEncode`). -/
def percentEncode (s : String) : String := Network.HTTP.Types.urlEncode s

/-- The GitHub API URLs for the branch check and the tarball. -/
def githubUrls (owner repo branch commit : String) : String × String :=
  let base := s!"https://api.github.com/repos/{percentEncode owner}/{percentEncode repo}"
  let branchPath := "/".intercalate ((branch.splitOn "/").map percentEncode)
  (s!"{base}/compare/{branchPath}...{commit}?per_page=1", s!"{base}/tarball/{commit}")

/-- The GitLab API URLs for the branch check and the archive. -/
def gitlabUrls (segments : List String) (branch commit : String) : String × String :=
  let base := s!"https://gitlab.com/api/v4/projects/{percentEncode ("/".intercalate segments)}/repository"
  (s!"{base}/merge_base?refs%5B%5D={percentEncode branch}&refs%5B%5D={commit}",
   s!"{base}/archive.tar.gz?sha={commit}")

/-- A download URL GitHub may redirect a tarball to. -/
def isCodeloadUrl (url : String) : Bool := url.startsWith "https://codeload.github.com/"

-- ── liaison ─────────────────────────────────────────────────────────────────

/-- `GET url` through liaison, with the request's credentials. The body and
    the reply are liaison's own wire format (`Liaison.Wire`); `cost` is `0`:
    fetching a repository spends no credits (the app's warrants carry
    `budget(0)`). -/
def viaLiaison (ctx : Context) (cred : Credentials) (resource : List String)
    (payload : Json) : IO Liaison.Wire.Response := do
  let some base := ctx.liaisonUrl
    | throw (IO.userError "this repository needs credentials, but LUN_LIAISON_URL is not set")
  -- liaison checks the warrant's expiry against the caller's clock.
  let secs := (← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000000
  let body ← IO.ofExcept <| (Liaison.Wire.Body.connector cred.warrant secs.toUInt64 0
    { account := cred.account, operation := "repositories.read", resource, payload := payload.compress }).mapError IO.userError
  let target := (if base.endsWith "/" then (base.dropEnd 1).toString else base) ++ "/v0/egress"
  let req ← Network.HTTP.Simple.parseUrl! target
  let req : Request := { req with
    method := Method.standard .POST
    headers := [(Data.CI.mk' "Content-Type", "application/json")]
    body := some body.encode.toUTF8
    timeoutMillis := ctx.timeoutMs }
  let resp ← Network.HTTP.Simple.httpBS req
  let text := String.fromUTF8? resp.body |>.getD ""
  match ← IO.ofExcept (Liaison.Wire.decodeReply resp.statusCode.statusCode text |>.mapError IO.userError) with
  | .relayed r => pure r
  | .refused status code => throw (IO.userError s!"liaison refused the call ({status} {code})")

/-- A liaison-relayed answer's body as JSON. -/
private def jsonBody (u : Liaison.Wire.Response) (what : String) : IO Json :=
  match String.fromUTF8? u.body >>= fun t => (Json.parse t).toOption with
  | some j => pure j
  | none => throw (IO.userError s!"{what}: the answer is not JSON")

private def expectOk (u : Liaison.Wire.Response) (what : String) : IO Unit :=
  unless u.status == 200 do
    let snippet := ((String.fromUTF8? u.body).getD "").take 200
    throw (IO.userError s!"{what}: the host answered {u.status} {snippet}")

-- ── Unpacking ───────────────────────────────────────────────────────────────

/-- Unpack a `.tar.gz` whose members sit under one top-level directory into
    `dest`. -/
def unpack (ctx : Context) (archive : ByteArray) (dest : System.FilePath) : IO Unit := do
  let file := dest.withExtension "tar.gz"
  IO.FS.writeBinFile file archive
  IO.FS.createDirAll dest
  let r ← System.Process.run "tar" #["-xzf", file.toString, "-C", dest.toString, "--strip-components=1"]
    ctx.timeoutMs
  IO.FS.removeFile file
  unless r.ok do throw (IO.userError (r.describe "tar"))

-- ── The three ways ──────────────────────────────────────────────────────────

private def git (ctx : Context) (args : Array String) (cwd : Option System.FilePath := none) :
    IO System.Process.Result :=
  System.Process.run "git" args ctx.timeoutMs cwd (env := System.Process.hermeticGit)

/-- A public repository, with `git`. -/
def withGit (ctx : Context) (src : Source) (dest : System.FilePath) : IO Unit := do
  let r ← git ctx #["clone", "--quiet", "--filter=blob:none", "--no-checkout", "--single-branch",
    "--branch", src.branch, "--", src.repo.cloneUrl, dest.toString]
  unless r.ok do
    throw (IO.userError (r.describe s!"cloning {src.repo.cloneUrl} (branch {src.branch})"))
  let r ← git ctx #["merge-base", "--is-ancestor", src.commit, "HEAD"] dest
  match r.exitCode with
  | some 0 => pure ()
  | some 1 => throw (IO.userError s!"commit {src.commit} is not on branch {src.branch}")
  | _ => throw (IO.userError (r.describe s!"looking for commit {src.commit}"))
  let r ← git ctx #["-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach",
    src.commit] dest
  unless r.ok do throw (IO.userError (r.describe s!"checking out {src.commit}"))

/-- A private GitHub repository, through liaison. -/
structure NativeFile where
  private mk ::
  components : List String
  valid : Liaison.Wire.validResource components = true
  bookkeeping : components.all (fun part => part.toLower != ".git" && part.toLower != ".lake") = true
  mode : String
  regular : (["100644", "100755"].contains mode) = true

def NativeFile.ofJson (entry : Json) : Except String NativeFile := do
  let name ← entry.getObjValAs? String "path"
  let components := name.splitOn "/"
  if h : Liaison.Wire.validResource components = true then
    if hb : components.all (fun part => part.toLower != ".git" && part.toLower != ".lake") = true then
      let mode ← entry.getObjValAs? String "mode"
      if hm : (["100644", "100755"].contains mode) = true then
        return ⟨components, h, hb, mode, hm⟩
      else throw "native checkout refuses symbolic links and submodules"
    else throw "native checkout refuses repository bookkeeping paths"
  else throw "native checkout path leaves its repository"

private theorem nativeFile_valid (file : NativeFile) :
    Liaison.Wire.validResource file.components = true := file.valid

private theorem nativeFile_regular (file : NativeFile) :
    (["100644", "100755"].contains file.mode) = true := file.regular

/-- Native immutable tree/file reads; no signed redirect or archive bypass. -/
private def fetchNativeTree (ctx : Context) (cred : Credentials) (src : Source) (dest : System.FilePath) : IO Unit := do
  let tree ← viaLiaison ctx cred src.repo.segments
    (Json.mkObj [("view", "tree"), ("ref", Json.str src.commit)])
  expectOk tree "reading the repository tree"
  let json ← jsonBody tree "reading the repository tree"
  unless (json.getObjValAs? Bool "truncated").toOption == some false do
    throw (IO.userError "native checkout refuses an incomplete tree")
  let entries ← IO.ofExcept ((json.getObjValAs? (Array Json) "tree").mapError IO.userError)
  unless entries.size ≤ 10000 do throw (IO.userError "native checkout has too many files")
  let mut files := #[]
  for entry in entries do
    if (entry.getObjValAs? String "type").toOption == some "tree" then continue
    unless (entry.getObjValAs? String "type").toOption == some "blob" do
      throw (IO.userError "native checkout refuses submodules")
    files := files.push (← IO.ofExcept ((NativeFile.ofJson entry).mapError IO.userError))
  if ← dest.pathExists then throw (IO.userError "native checkout requires a fresh private directory")
  IO.FS.createDirAll dest
  let mut total := 0
  for file in files do
    let response ← viaLiaison ctx cred (src.repo.segments ++ file.components)
      (Json.mkObj [("ref", Json.str src.commit)])
    expectOk response "reading an immutable repository file"
    let json ← jsonBody response "reading an immutable repository file"
    unless (json.getObjValAs? String "encoding").toOption == some "base64" do
      throw (IO.userError "native repository file is not base64")
    let content ← IO.ofExcept ((json.getObjValAs? String "content").mapError IO.userError)
    let some bytes := Data.Base64.decode ((content.replace "\n" "").replace "\r" "")
      | throw (IO.userError "invalid repository base64")
    total := total + bytes.size
    unless total ≤ 64 * 1024 * 1024 do throw (IO.userError "native checkout exceeds 64 MiB")
    let target := file.components.foldl (fun path component => path / component) dest
    if let some parent := target.parent then IO.FS.createDirAll parent
    IO.FS.writeBinFile target bytes
    if file.mode == "100755" then
      let r ← System.Process.run "chmod" #["+x", target.toString] ctx.timeoutMs
      unless r.ok do throw (IO.userError (r.describe "restoring executable mode"))

def fromGitHub (ctx : Context) (cred : Credentials) (src : Source) (dest : System.FilePath) :
    IO Unit := do
  let (owner, repo) ← match src.repo.segments with
    | [o, r] => pure (o, r)
    | _ => throw (IO.userError "a GitHub repository is OWNER/REPO")
  let cmp ← viaLiaison ctx cred [owner, repo]
    (Json.mkObj [("view", "ancestry"), ("ref", Json.str src.commit), ("branch", Json.str src.branch)])
  if cmp.status == 404 then
    throw (IO.userError s!"branch {src.branch} or commit {src.commit} not found")
  expectOk cmp "comparing the commit with the branch"
  let status := ((← jsonBody cmp "comparing").getObjValAs? String "status").toOption
  unless status == some "behind" || status == some "identical" do
    throw (IO.userError s!"commit {src.commit} is not on branch {src.branch}")
  fetchNativeTree ctx cred src dest

/-- A private GitLab repository, through liaison. -/
def fromGitLab (ctx : Context) (cred : Credentials) (src : Source) (dest : System.FilePath) :
    IO Unit := do
  unless src.repo.segments.length == 2 do
    throw (IO.userError "nested GitLab namespaces require a native repository-selector adapter")
  let mb ← viaLiaison ctx cred src.repo.segments
    (Json.mkObj [("view", "ancestry"), ("ref", Json.str src.commit), ("branch", Json.str src.branch)])
  if mb.status == 404 then
    throw (IO.userError s!"branch {src.branch} or commit {src.commit} not found")
  expectOk mb "finding the merge base of the commit and the branch"
  let base := ((← jsonBody mb "merge base").getObjValAs? String "id").toOption
  unless base == some src.commit do
    throw (IO.userError s!"commit {src.commit} is not on branch {src.branch}")
  fetchNativeTree ctx cred src dest

/-- Fetch `src` into `dest` (which must not exist). -/
def fetch (ctx : Context) (src : Source) (dest : System.FilePath) : IO Unit :=
  match src.credentials, src.repo.host with
  | none, _ => withGit ctx src dest
  | some cred, .github => fromGitHub ctx cred src dest
  | some cred, .gitlab => fromGitLab ctx cred src dest
  | some _, _ => throw (IO.userError "credentials are only usable for github.com and gitlab.com")

end Lun.Fetch
