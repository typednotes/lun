# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28). The moves
into linen were done in lun 0.2.2 with linen 1.7.0 (and lode, liaison in the
same pass); also, the test library is `LunTest`, the package's `testDriver`
(`lake test`), and CI and the Dockerfile take linen's native dependency list.
Each open item names where it comes from; re-check before acting.

Moves into linen follow linen's `AGENTS.md` ("Importing external code"): the
linen change and the deletion here (and in lode) happen in the same pass.

## Security

- [ ] **linen's `FileSystem` capability can be escaped with `..`.** Checked
  against linen v1.6.1: a capability scoped to `["tmp","sandbox"]` permits
  `["tmp","sandbox","..","..","etc","passwd"]`, because `Scope.covers` is a
  component prefix test (`linen/Linen/Control/Monad/Effect/FileSystem.lean:245`)
  and `..` is an ordinary component; `Path.toFilePath` also drops the leading
  `/`, so paths resolve against the working directory. User functions may use
  the `FileSystem` effect (`template/LunDriver/Runtime.lean:135`), so a scope
  lun hands them does not confine them. **Fix in linen** (reject `.`, `..` and
  empty components; keep absolute paths absolute; optionally a symlink-aware
  check like lode's `Env.confine`), then raise lun's linen floor. Until then,
  the container is the only boundary for file access.
- [ ] **Check user sources before compiling them.** lun builds untrusted
  projects with the project's own lakefile running (`Lun/Driver.lean:121`), and
  `lun_function` only rejects `unsafe`/`sorry` on the declared constant
  (`Runtime.lean:182,207`); `AGENTS.md:111-117` names the container as the only
  boundary. linen's `System.GitFn` does this properly: `checkProject`
  (`linen/Linen/System/GitFn/Policy.lean`) before anything compiles, admitted
  modules copied into a generated package (so the remote lakefile never runs),
  and a post-compile check (unsafe/extern/implemented_by/partial/axioms). Needs
  linen ≥1.6.1 (earlier versions leak a Lean environment per check). Caveats:
  GitFn pins the host toolchain, lun uses the project's (`Driver.lean:129`);
  the policy rejects `macro`/`notation`/`initialize` (a product decision); and
  linen keeps one environment per distinct set of imports for the process's
  life, so a long-running server fed arbitrary projects still grows — ask linen
  for a bounded mode (e.g. the union of the allowed libraries, loaded once). (M–L)
- [x] **Constant-time compare into linen.** `Crypto.ConstantTime` (linen
  1.7.0); lun's copy is gone. Still open: bearer auth as a linen middleware,
  and reading request bodies with `requestSizeLimit` (`Server.lean`) as lode
  does. (S)

## Shared with lode — moved into linen (1.7.0)

- [x] **Process runner with deadline** → `System.Process`; `Lun/Process.lean`
  is gone. Fixes a bug lun had: after `Child.takeStdin`, Lean 4.34's
  `Child.kill` signals the leader only, so a timed-out `lake build` left its
  workers running and waited for them. linen's GitFn builds now have a
  deadline too.
- [x] **lake log diagnostics parser** → `System.LakeLog`; lun's scoping to its
  driver files stays in `Lun/Diagnostics.lean`.
- [x] **Validation helpers**: commit ids are `CommitSha.isValid`, branches and
  repository URLs `System.Git.Remote`, `percentEncode` is linen's `urlEncode`.
  Still open: package-cache seeding (`Build.lean`) duplicates lode's, which
  parses the manifest with Lake's parser rather than by hand; the codeload
  download stays (three lines per service). (S)

## Smaller

- [ ] `Spec.lean:114` prints JSON and re-parses it; `Data.Json.Value.ofLeanJson`
  (`linen/Linen/Data/Json/Bridge.lean:35`) converts directly (lode uses it).
- [ ] The runtime's ban list (`Runtime.lean:333-338`) predates linen 1.4.0 and
  does not name newer helpers such as `Reactive.remote`; safety rests on
  `GraphImpl.ofGraph` replacing every function (`:386-390`) — worth a test.
- [ ] The Dockerfile's warm-cache imports (`Dockerfile:52-57`) repeat
  `Runtime.lean:35-40` by hand and can drift.
- [ ] `test/fixture/lakefile.toml:5-9` says linen is used by path "before they
  are tagged" — tagged since 1.3.0.
- [ ] Longer term: linen's stdio JSON-RPC worker could keep drivers alive
  instead of a process per call (`Build.lean:349`), once it takes a per-call
  timeout and keeps stderr (`linen/.../GitFn/Worker.lean:59,74-80`).
