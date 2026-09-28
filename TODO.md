# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28). The bump
itself needed no code change (lun imports nothing linen 1.6.x changed). Each
item names where it comes from; re-check before acting.

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
- [ ] **Constant-time compare and bearer auth into linen.** `constantTimeEq`
  and `authorized` (`Lun/Server.lean:55-69`) are identical in lode; linen has
  only `basicAuth`. Also read request bodies with linen's `requestSizeLimit`, as
  lode does, instead of by hand (`Server.lean:45-52`). (S)

## Shared with lode — move into linen

- [ ] **Process runner with deadline** (`Lun/Process.lean:30-69`) — lode's copy
  is a superset (abort flag, binary output). linen's GitFn builds need the
  same: they run `lake build` with no timeout (`linen/.../GitFn/Build.lean:89-92`). (S)
- [ ] **lake log diagnostics parser** (`Lun/Diagnostics.lean`): `parse` is
  byte-identical to lode's; GitFn could return parsed diagnostics too. lun's
  scoping to its driver files stays here. (S)
- [ ] **Validation and fetch helpers.** `Validate.lean:54-55` is
  `CommitSha.isValid` (`linen/Linen/System/GitFn/Descriptor.lean:40-41`, which
  lode already uses); branch/repo validators and the codeload tarball fetch are
  near-identical to lode's; `Fetch.lean:45` re-implements linen's `urlEncode`;
  package-cache seeding (`Build.lean:205-215`) duplicates lode's, which parses
  the manifest with Lake's parser rather than by hand. (S–M)

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
