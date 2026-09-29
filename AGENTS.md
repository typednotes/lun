# lun — agent notes

`lun` compiles a Lean project (a git repository at a commit) into typed
services: one per declared **function** (a Lean function under a declared
signature) and one per **graph** of functions (a program in linen's
`Reactive` monad), which can also run as a live **session** (update some
inputs, get back what changed). The vocabulary is linen's: functions, graphs,
inputs, nodes, sessions. See `README.md` for the API.
It is the runner; `lode` is the agent that writes the projects it runs —
do not confuse the two.
Built on `linen` (pinned `v1.9.2` for lun itself; user projects need
linen ≥ `1.3.0`, the first with the `Control.Reactive` the runtime uses).
Speaks to `liaison` with liaison's own wire module, `Liaison.Wire` (pinned
`v0.5.5`).

## Layout

- `Lun/Validate.lean` — the grammar of every string a request carries
  (names, commit, project path, embedded Lean text). Pure. Branch names and
  repository URLs are linen's `System.Git.Remote` (`isBranchName`,
  `Repository.parse`), which lode uses too, so the two agree.
- `Lun/Spec.lean` — the build request: `BuildSpec.parse` (the only place a
  request is interpreted) and `BuildSpec.canonical` (no credentials; what ids
  are computed from and what is persisted). A warrant is decoded with
  `Liaison.Wire.decodeWarrant`, exactly as liaison decodes it.
- `Lun/Manifest.lean` — the project may depend on linen only (read from its
  committed `lake-manifest.json`).
- `Lun/Driver.lean` — the generated driver package (`files`): one module per
  function and per graph. Embeds `template/LunDriver/Runtime.lean` with
  `include_str` (tracked by the lakefile's `input_file driverRuntime`, so an
  edited runtime rebuilds `Lun.Driver`). Pure.
- `template/LunDriver/Runtime.lean` — **the driver runtime**, copied into
  every driver. `FunctionType` (which Lean types can be served and how to
  call them on JSON), graphs over linen's `Control.Reactive` (`input`, in
  `LunDriver.Dsl`, and each function as an operator: a `combineLatest` over
  it, built in the scope `«#function».«name»` so its label names it), the
  `lun_function` and `lun_graph` commands (the signature and graph checks, as
  elaborators; `GraphImpl.ofGraph` validates a built graph and replaces its
  every function by the declared one its label names), sessions
  (`SessionState`: linen's `Session` clock and operator state plus every
  node's outcome, as JSON; `GraphImpl.feed` restores it and pushes
  occurrences; values travel wrapped — `okValue`/`failedValue`/`blockedValue`
  — so a failure never ends a node's stream), `runGraph`/`sessionStart`/
  `sessionUpdate`, and `driverMain` (the executable's stdin/stdout
  protocol). It imports linen ≥ 1.3.0 modules
  (verified against 1.3.0 and 1.5.0), so it is **not** part of lun's own
  build: it is compiled only inside a driver. `test/e2e.sh` is what
  exercises it; `LunTest/Lun/DriverTest.lean` only checks it is embedded.
- `Lun/Diagnostics.lean` — `lake build` diagnostics (parsed by linen's
  `System.LakeLog`) attributed to a function, graph (with the line in the
  program), the project, the driver, or the build. Pure.
- Commands run through linen's `System.Process.run` (deadline, process group
  killed) with its `hermeticGit`; the bearer token is compared with linen's
  `Crypto.ConstantTime`.
- `Lun/Fetch.lean` — `git` for public repositories; GitHub/GitLab REST
  through liaison for private ones.
- `Lun/Build.lean` — ids, statuses (`status.json`, atomic writes), the build
  pipeline (fetch → check, then under a lock generate → `lake build` →
  describe), the package-cache seeding, and `Builder.call` (running a ready
  driver).
- `Lun/Session.lean` — sessions: stored under `{workdir}/sessions/` (atomic
  writes), one lock per session, driven through `Builder.call`
  (`session-start`/`session-update`).
- `Lun/Server.lean` — the HTTP routes. `Main.lean` — environment.
- `Examples/` — `pricing/` (a user project: an invoice's functions),
  `Client.lean` (`lake exe lun-example`: build, register the invoice graph as
  a session, update inputs, print what changed; `--dot` draws it) and
  `run.sh` (a local lun running the client). `docs/invoice.svg` is its
  `--dot` output, rendered by Graphviz, shown in the README.
- `test/fixture/` — a user project for the end-to-end test (functions that pass,
  `Fixture/Rejected.lean` for ones that must not). `test/e2e.sh` — the
  end-to-end test.

## Running tests

```
lake test
test/e2e.sh ../linen      # needs jq, git, and a linen checkout >= 1.3.0
```

`test/e2e.sh` picks a free port, runs lun with `LUN_ALLOW_LOCAL=1`, and
takes a couple of minutes (it builds the fixture's driver ten times).
`Examples/run.sh ../linen` runs the example (about 30 s with a built linen).

## Conventions

- As in linen: no `sorry`; document definitions; `── … ──` section banners.
  `repeat` loops are used for polling (processes, request bodies); no
  `partial def`.
- Everything that interprets untrusted input is pure and unit-tested
  (`Validate`, `Spec`, `Manifest`, `Driver`, `Diagnostics`).
- liaison's wire format is liaison's: lun imports `Liaison.Wire` (the module
  liaison's server parses with, tested there) and never writes or reads
  `POST /v0/egress` JSON itself. Import nothing else from liaison: `lun`
  builds only `Liaison.Wire` and the warrant types. (`LunTest`, being
  `precompileModules`, builds liaison's whole library as a shared object;
  that is harmless — a library link — but it is why it builds liaison's
  Postgres modules.)
- Request text is never spliced into generated code: names are validated and
  `«quoted»`, signatures and programs are raw string literals parsed as one term
  by the runtime. Keep it that way.

## Git

**Never run `git push` in this repo.** Commits are fine when asked for; pushing
is always left to the user.

## Known gaps (named, not silent)

- **The container image has not been built here** (the local podman needed an
  interactive registry login). The Linux link of `lun` and of drivers is
  unverified; lun's own link and the drivers' were verified on macOS.
- **Types are not a sandbox.** The checks bind the *declared* authority of a
  function (its effect row, handled by linen's handlers), but a project's code can
  still reach arbitrary `IO` through `unsafe` definitions, `@[implemented_by]`
  or `@[extern]` deeper inside a function (only the declared function itself
  is checked for `unsafe`), and its `lakefile.lean` runs arbitrary code at build
  time. The container is the isolation boundary; run lun with no credentials
  of its own and no network access beyond what builds need.
- **The graph check is a walk, a denylist and a graph check, not a proof.** The
  walk refuses the builder's primitives (`Reactive.register`, `addNode`,
  `fnImpl`, `fn`, `Builder.mk`, `Graph.mk`, `Graph.rebind`, `Operator.*`)
  anywhere in the graph's non-library code; library functions are trusted, not
  walked. What makes it safe is the graph check (`GraphImpl.ofGraph`): only inputs
  and `combineLatest`s over functions labelled as declared functions, with their
  arities, and every function replaced by that function before anything runs.
  Known consequences, neither of which breaks safety (every value is decoded
  by the declared function it reaches): a function registered by a library
  operator inside `scope «#function».«name»` is accepted and runs as that function
  (so its observable's type may be the wrong one); an observable taken out of
  a *separate* `Reactive.build` names a node index of another graph, which
  linen's build accepts if that index is earlier.
- **Graphs are function applications only.** linen's other operators (`map`,
  `filter`, `scan`, the timed ones, …) and `Operator`s are refused: they would
  run Lean code that is not a declared function (`mapM` even `IO`), and a graph
  request is one instant (every input fed once at time 0), not a stream.
- **An `input` cannot be relabelled** (`node x ← input "x" Nat` fails: the
  input's label is its name). `node` works on function applications.
- **`HTTP` and `FileSystem` functions act from lun's container directly**, not
  through liaison: no credentials, no metering, no audit row. Their capability
  (in the signature) bounds what they may reach.
- **Functions run in-process per call**: each call spawns the driver (no
  long-running per-function service, no pooling). Graphs evaluate
  sequentially.
- **A session update with several inputs** feeds them in order at one instant
  of linen's clock: a function reading two of them may run for the
  intermediate state too (only the final outcomes are reported).
- **Sessions are never collected**: they stay until `DELETE`d; a stored
  session whose build is gone fails its next update.
- **One compilation at a time** (fetches run concurrently). A queued build's
  warrant is used as soon as the build starts fetching, not after the queue.
- **Private repositories**: github.com and gitlab.com only (the connections'
  `base_url`s); archives are held in memory; submodules are not fetched on
  either path. GitLab's archive, GitHub's compare and GitLab's merge-base go
  through liaison; GitHub's signed tarball URL is fetched directly.
- **Only `Trace`, `Error`, `HTTP`, `FileSystem`** effects are allowed in a function
  (those with a configuration-free `Handler _ IO` in linen). `Reader`, `State`,
  `PostgreSQL`, … would need configuration lun does not have.
- **A project linked to a linen revision the package cache lacks** builds its
  linen from scratch (correct but slow). The cache holds one revision.
- **Build ids change across restarts unless `LUN_ID_SALT` is set.**
