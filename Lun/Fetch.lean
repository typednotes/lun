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
def viaLiaison (ctx : Context) (cred : Credentials) (url : String)
    (headers : List (String × String) := []) : IO Liaison.Wire.Response := do
  let some base := ctx.liaisonUrl
    | throw (IO.userError "this repository needs credentials, but LUN_LIAISON_URL is not set")
  -- liaison checks the warrant's expiry against the caller's clock.
  let secs := (← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000000
  let body ← IO.ofExcept <| (Liaison.Wire.Body.provider cred.warrant secs.toUInt64 0
    { account := cred.account, method := "GET", url, headers }).mapError IO.userError
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
def fromGitHub (ctx : Context) (cred : Credentials) (src : Source) (dest : System.FilePath) :
    IO Unit := do
  let (owner, repo) ← match src.repo.segments with
    | [o, r] => pure (o, r)
    | _ => throw (IO.userError "a GitHub repository is OWNER/REPO")
  let (compareUrl, tarballUrl) := githubUrls owner repo src.branch src.commit
  let accept := [("accept", "application/vnd.github+json")]
  let cmp ← viaLiaison ctx cred compareUrl accept
  if cmp.status == 404 then
    throw (IO.userError s!"branch {src.branch} or commit {src.commit} not found")
  expectOk cmp "comparing the commit with the branch"
  let status := ((← jsonBody cmp "comparing").getObjValAs? String "status").toOption
  unless status == some "behind" || status == some "identical" do
    throw (IO.userError s!"commit {src.commit} is not on branch {src.branch}")
  let tar ← viaLiaison ctx cred tarballUrl accept
  let archive ← if tar.status == 200 then pure tar.body else
    match tar.status, tar.header? "location" with
    | 302, some loc =>
      unless isCodeloadUrl loc do
        throw (IO.userError s!"GitHub redirected the tarball to an unexpected host")
      let req ← Network.HTTP.Simple.parseUrl! loc
      let resp ← Network.HTTP.Simple.httpBS { req with timeoutMillis := ctx.timeoutMs }
      unless resp.statusCode.statusCode == 200 do
        throw (IO.userError s!"downloading the tarball: {resp.statusCode.statusCode}")
      pure resp.body
    | s, _ => throw (IO.userError s!"fetching the tarball: the host answered {s}")
  unpack ctx archive dest

/-- A private GitLab repository, through liaison. -/
def fromGitLab (ctx : Context) (cred : Credentials) (src : Source) (dest : System.FilePath) :
    IO Unit := do
  let (mergeBaseUrl, archiveUrl) := gitlabUrls src.repo.segments src.branch src.commit
  let mb ← viaLiaison ctx cred mergeBaseUrl
  if mb.status == 404 then
    throw (IO.userError s!"branch {src.branch} or commit {src.commit} not found")
  expectOk mb "finding the merge base of the commit and the branch"
  let base := ((← jsonBody mb "merge base").getObjValAs? String "id").toOption
  unless base == some src.commit do
    throw (IO.userError s!"commit {src.commit} is not on branch {src.branch}")
  let ar ← viaLiaison ctx cred archiveUrl
  expectOk ar "fetching the archive"
  unpack ctx ar.body dest

/-- Fetch `src` into `dest` (which must not exist). -/
def fetch (ctx : Context) (src : Source) (dest : System.FilePath) : IO Unit :=
  match src.credentials, src.repo.host with
  | none, _ => withGit ctx src dest
  | some cred, .github => fromGitHub ctx cred src dest
  | some cred, .gitlab => fromGitLab ctx cred src dest
  | some _, _ => throw (IO.userError "credentials are only usable for github.com and gitlab.com")

end Lun.Fetch
