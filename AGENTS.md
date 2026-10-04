# lun — agent notes

`lun` compiles a Lean project (a git repository at a commit) into typed
services: one per declared **function** (a Lean function under a declared
signature) and one per **graph** of functions (a program in linen's
`Reactive` monad). Execution is stateless: the caller supplies JSON state and
inputs, receives changed values, updated state and `nextCallAt`, persists state
in its database, and schedules further calls. Lun retains compiled code in warm
workers, never execution records. See `README.md` and `docs/user-guide.md`.
Current runner release: **Lun 0.4.2**, with Linen 1.12.0 and Liaison's pure
0.6.0 SDK. The release set below records the earlier whole-pipeline verification.
It is the runner; `lode` is the agent that writes the projects it runs —
do not confuse the two.
Coordinated release set: **Lun 0.3.0 / Lode 0.3.0 / Typednotes 0.6.0 /
Linen 1.10.0 / Liaison 0.6.0**. The current driver requires the Linen connector
APIs and Liaison's pure `Liaison.Wire` SDK; the historical 1.3.0 Reactive minimum
is not sufficient for this runtime. Package locks and image/default pins use the
current runner's dependency versions. Publishing the local release tags and deploying remain the user's actions.

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
  edited runtime rebuilds `Lun.Driver`), plus the descriptor-relative temporary
  syscall adapter. The generated package uses the user manifest's Linen source,
  requires Liaison `v0.6.0`, and accepts `LUN_LIAISON_SDK_PATH` only in local mode.
  Generation is pure.
- `template/LunDriver/Runtime.lean` — **the driver runtime**, copied into
  every driver. `FunctionType` (which Lean types can be served and how to
  call them on JSON), graphs over linen's `Control.Reactive` (`input`, in
  `LunDriver.Dsl`, and each function as an operator: a `combineLatest` over
  it, built in the scope `«#function».«name»` so its label names it), the
  `lun_function` and `lun_graph` commands (the signature and graph checks, as
  elaborators; `GraphImpl.ofGraph` validates a built graph and replaces its
  every function by the declared one its label names), `ProducerType`/
  `lun_producer` (arguments followed by `Nat → Option S → Eff effs
  (List B × S × Option Nat)`; typed continuations and emitted values), and
  `GraphState`/`runGraph` (caller-owned outcomes, continuations and pending
  emissions; topological propagation; changed intermediate/sink values plus a
  Unix-millisecond next-call timestamp). Values travel wrapped —
  `okValue`/`failedValue`/`blockedValue` — so failed nodes can recover.
  `driverMain` implements the executable's stdin/stdout
  protocol). Canonical handlers run in `ReaderT ExecutionContext IO`.
  `OutputContract`, `WiringContract` and `SourceContract` provide kernel-checked
  caller-owned output, ordered named wiring and source-type/layout guarantees;
  runtime binding consumes witnesses for the actual graph. Executable closure
  auditing and graph validation remain additional checks, not sandbox proofs.
  The template is compiled inside generated drivers, exercised by `test/e2e.sh`
  and `test/runtime.py`; `LunTest/Lun/DriverTest.lean` checks generation/embedding.
- `Lun/Diagnostics.lean` — `lake build` diagnostics (parsed by linen's
  `System.LakeLog`) attributed to a function, graph (with the line in the
  program), the project, the driver, or the build. Pure.
- Commands run through linen's `System.Process.run` (deadline, process group
  killed) with its `hermeticGit`; the bearer token is compared with linen's
  `Crypto.ConstantTime`.
- `Lun/Fetch.lean` — `git` for public/local repositories; private GitHub/GitLab
  use broker-owned `repositories.read` ancestry, complete immutable tree and
  per-file views. Private `NativeFile` witnesses carry selector/bookkeeping/
  regular-file evidence. No archive, signed-download or generic-provider bypass.
- `Lun/Build.lean` — ids, statuses (`status.json`, atomic writes), the build
  pipeline (fetch → check, then under a lock generate → `lake build` →
  describe → preload), package-cache seeding, and `Builder.call` (running a ready
  driver through a warm process cache). `Lun/WorkerCache.lean` preloads and
  handshakes compiled code; an unused process binds once to an actor/entry point.
  There is no session API/storage: fresh authority is supplied on every call.
- `Lun/Server.lean` — the HTTP routes. `Main.lean` — environment.
- `Examples/` — `pricing/` (a user project: an invoice's functions),
  `Client.lean` (`lake exe lun-example`: build, retain the invoice graph's state
  in the caller, update inputs, print what changed; `--dot` draws it) and
  `run.sh` (a local lun running the client). `docs/invoice.svg` is its
  `--dot` output, rendered by Graphviz, shown in the README.
- `test/fixture/` — a user project for the end-to-end test (functions that pass,
  `Fixture/Rejected.lean` for ones that must not). `test/e2e.sh` — the
  end-to-end test.

## Running tests

```
lake test
test/e2e.sh ../linen      # jq, git and the coordinated Linen/Liaison checkouts
python3 test/temporary_test.py /path/to/scratch
PATH=/path/to/postgresql/bin:$PATH python3 test/runtime.py --temp-root /path/to/scratch
```

`test/e2e.sh` picks a free port, runs lun with `LUN_ALLOW_LOCAL=1`, and compiles
multiple positive/refusal fixtures; allow sufficient time for native driver
builds. Use `LUN_E2E_WORKSPACE` for unpublished sibling overrides. The runtime
fixture executes actual SCRAM queries and the real HMAC broker with local vault/
provider peers. See `docs/runtime-guarantees.md` for full reproduction.

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

For a new release commit, the user can push main and its version tag together.
The publisher waits up to two hours for that exact commit's latest push-to-main
CI success; all existing main CI jobs remain required. Failed/cancelled CI,
invalid evidence, API errors and timeout stop publication. Existing tags retain
their original workflows and must not be moved to adopt this behavior.

**Never run `git push` in this repo.** Commits are fine when asked for; pushing
is always left to the user.

## Verified contracts and remaining boundaries

- **Historical release verification:** the full Lun end-to-end suite and 69 compiled
  runtime cases pass; the app's suite additionally passes 99 API tests, 24 browser
  groups and the full app → compiled Lode → broker → local Git → compiled Lun
  positive/denial pipeline. Liaison passes 655 real broker HTTP cases. Controlled
  provider replies do not establish live paid-provider/OAuth conformance.

- **The container image has not been built here** (the local podman needed an
  interactive registry login). The Linux link of `lun` and of drivers is
  unverified; lun's own link and the drivers' were verified on macOS.
- **Types are not a sandbox.** The executable closure and JSON dictionaries are
  now audited transitively for unsafe/implemented-by/extern, axioms, project
  initializers and raw IO/runtime entry points. Lakefiles and metaprograms still
  execute during builds; the build container and trusted library/FFI remain the
  isolation boundary. Private service context is injected only after compilation,
  and service credentials are stripped from child environments. See
  `docs/runtime-guarantees.md` for the exact trusted boundaries.
- **Graph guarantees are proved and checked.** `OutputContract` proves the
  caller-owned result type, `WiringContract` proves ordered named direct arguments,
  and `SourceContract` proves configured source presence/layout; checked input
  constructors consume actual type equality. `BoundWiring`/`BoundSources` require
  equality with the runtime graph before execution. The transitive walk additionally
  refuses builder primitives/raw subjects and the graph validator rebinds all
  implementations to declared functions. These are specific kernel guarantees,
  not a proof of arbitrary library code or a general process sandbox.
- **Graphs are function applications only.** linen's other operators (`map`,
  `filter`, `scan`, the timed ones, …) and `Operator`s are refused: they would
  run Lean code that is not a declared function (`mapM` even `IO`). Resumable
  producers run only declared, audited steps; delays are scheduled by the caller.
- **An `input` cannot be relabelled** (`node x ← input "x" Nat` fails: the
  input's label is its name). `node` works on function applications.
- **Anonymous `HTTP` and temporary `FileSystem` operations** act locally.
  `AuthorizedHTTP` consumes static scope, org domain/standard-port permission and
  public DNS-address evidence; transport pins that address and follows no redirects.
  `TemporaryPath` consumes static rights and an org/user-bound relative selector;
  descriptor-relative syscalls refuse traversal/symlinks and unsafe hard-link reads.
  These calls have no broker credential/metering/audit row; FFI/syscalls and the
  build/container boundary remain trusted.
- **Functions run in loaded workers**: compilation preloads a compiled driver
  when capacity is available. Exact actor/build/entry-point matching governs
  reuse after its first execution. Graph nodes evaluate sequentially.
- **Several input changes** are fed in order at the request's timestamp. A
  function may run for intermediate combinations too; every changed outcome is
  reported, followed by the final node snapshot. Bursts are retained individually.
- **State and scheduling are caller-owned**: no state is persisted by Lun. A
  producer's wake-up must be strictly after `now`; pending bursts surviving the
  256-occurrence call budget request an immediate follow-up. Input events restart
  producers and cancel obsolete continuations/emissions. Replay can repeat effects.
- **One compilation at a time** (fetches run concurrently). A queued build's
  warrant is used as soon as the build starts fetching, not after the queue.
- **Private repositories:** github.com/gitlab.com, unambiguous `[owner,repo]`,
  SHA-1 commits, bounded complete trees and regular files only. Native ancestry/
  tree/file requests stay brokered. Nested GitLab namespaces, native SHA-256
  repositories, symlinks and submodules are explicit refusals.
- **Eight canonical runtime effects** are supported: Trace, Error, HTTP,
  FileSystem, Connector, PostgreSQL, SecretStore and ObjectStore. Bound compute,
  graph-vault and object operations require explicit grants and private runtime
  configuration. Historical vault versions, arbitrary object write metadata,
  binary object writes and caller pagination cursors remain explicit refusals.
  Other rows (Reader, State, custom effects) are refused; there is no IO fallback.
- **Historical app/runtime integration:** trusted actor-bound compute and
  graph-vault grants, live three-document provisioning/revocation, source recovery
  with `recoverInputs:true`, and organization writer-tool forwarding/narrowing
  were exercised by the earlier whole-pipeline fixture. Current callers must
  adopt stateless graph steps, persist state and schedule wake-ups. Local PostgreSQL/SecretStore
  authorization trusts the authenticated app and vault-protected projections;
  local HMAC authenticity is not independently verified in Lun. Outbound
  Connector/ObjectStore HMAC checks execute at Liaison.
- **A project linked to a linen revision the package cache lacks** builds its
  linen from scratch (correct but slow). The cache holds one revision.
- **Build ids change across restarts unless `LUN_ID_SALT` is set.**
