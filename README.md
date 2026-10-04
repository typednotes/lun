<p align="center">
  <img src="logo.svg" alt="lun" width="180">
</p>

<h1 align="center">lun</h1>

<p align="center">
  <em>Typed, resumable graphs from a Lean project: supply state, get changed values and the next wake-up.</em>
</p>

<p align="center">
  <a href="https://github.com/typednotes/lun/actions/workflows/lean_action_ci.yml"><img src="https://github.com/typednotes/lun/actions/workflows/lean_action_ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/typednotes/lun/actions/workflows/docker-publish.yml"><img src="https://github.com/typednotes/lun/actions/workflows/docker-publish.yml/badge.svg" alt="Docker publish"></a>
  <a href="https://github.com/typednotes/lun/pkgs/container/lun"><img src="https://img.shields.io/badge/ghcr.io-typednotes%2Flun-blue?logo=docker" alt="Docker image"></a>
  <a href="https://github.com/typednotes/lun/tags"><img src="https://img.shields.io/github/v/tag/typednotes/lun?label=version&sort=semver" alt="Version"></a>
  <a href="https://lean-lang.org/"><img src="https://img.shields.io/badge/Lean-v4.34.0-blue" alt="Lean v4.34.0"></a>
   <a href="https://github.com/typednotes/linen"><img src="https://img.shields.io/badge/built%20on-linen%20v1.12.0-c9b896" alt="Built on linen v1.12.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache 2.0"></a>
</p>

---

`lun` turns a Lean project — a git repository pinned at a commit, or a local
working folder — into typed
services. You name some of its **functions**, each under a declared signature,
and some **graphs**: programs in [`linen`](https://github.com/typednotes/linen/tree/main)'s
reactive `Control.Reactive` monad that wire those functions together. lun
fetches the project, checks every signature and every graph, compiles it, and
serves it over HTTP or stdin/stdout. Graph execution is **stateless**: a call
accepts inputs and optional previous state, and returns changed intermediate/sink
values, updated JSON state, and `nextCallAt`. The caller persists that state in
its database and schedules further calls. Compiled code stays loaded in warm workers.

**New to Lun? Read the [illustrated user guide](docs/user-guide.md)** for the
build/run mental model, SVG figures, and a verified cookbook of CLI, HTTP,
function, stateless graph, delayed-producer, error-recovery and scoped-effect examples.

**Lun 0.4.1** adds illustrated, runnable sequential producer recipes with
Linen's `yield`, `yieldAll`, waits, branches and loops. Bounded loaded workers
and caller-owned resumable execution retain the `stateless-producers-v4` contract.
See [release preparation](docs/release-0.4.1.md): publish Linen 1.12.0 before
publishing this runtime. The dependency is pinned and locked to its exact local
release commit. Liaison's pure SDK remains
0.6.0; the deployed broker remains 0.6.3.

The new repeatable [arithmetic graph benchmark](docs/throughput.md) measures the
actual compiled HTTP paths before and after process caching. The current harness
measures fresh and caller-state graph calls; published session numbers are historical.
The cache retains checked templates and rebuilds execution context and authority
on every request; measured results and methodology are linked above. Deploying
this optimization requires the new runtime image.

<p align="center">
  <img src="docs/invoice.svg" alt="The invoice graph of the example, after its country input changed: shipping, vat, total and euros changed, subtotal and discounted did not run" width="760">
</p>

<p align="center"><sub>The example's <code>invoice</code> graph after <code>{"country": "DE"}</code>, drawn with Graphviz by <code>lake exe lun-example --dot</code>.</sub></p>

The projects it runs are the ones [`lode`](https://github.com/typednotes/lode/tree/main),
the agent, writes; private repositories and outbound connector credentials are
handled through [`liaison`](https://github.com/typednotes/liaison/tree/main). Bound local
compute and graph-vault effects use lun's private service identity.

## Table of contents

- [User guide](docs/user-guide.md)
- [Features](#features)
- [Example](#example)
- [Local interactive quickstart](#local-interactive-quickstart)
- [CLI](#cli)
- [Functions and graphs](#functions-and-graphs)
- [What is checked](#what-is-checked)
- [HTTP API](#http-api)
- [Configuration](#configuration)
- [Docker](#docker)
- [Development](#development)
- [Project status](#project-status)
- [License](#license)

## Features

- **Local development and two transports** — test a committed local Git
  repository or snapshot a working folder, including uncommitted edits.
  `lun cli` accepts JSON lines on stdin and returns JSON lines on stdout;
  `lun serve` exposes the same builds, functions and stateless graph steps over REST.

- **Loaded compiled workers** — bounded actor/build/entry-point cache, fresh
  request authority, deadline-aware queues and correlated replies. Graph state
  belongs to the caller; failed calls are never replayed. `LUN_WORKERS` defaults to 4
  and accepts 1–16. A newly compiled build is preloaded and handshaken before
  becoming ready, subject to worker capacity; its first call binds that warm
  process to the actor and entry point. Old driver artifacts are refused and rebuilt.

- **Typed functions** — a function of the project is served only if it *is*
  a function of its declared signature `α₁ → … → αₙ → Eff effs β`, with JSON
  arguments and result, whose effects use canonical bounded runtime handlers:
  `Trace`, `Error`, `HTTP`, `FileSystem`, `Connector`, `PostgreSQL`, `SecretStore`
  and `ObjectStore`.
- **Notebook authority** — caller-owned output/source types, four-ceiling
  connector scopes, fresh authenticated bindings, schema-confined compute and
  descriptor-relative temporary files. See [runtime guarantees](https://github.com/typednotes/lun/blob/main/docs/runtime-guarantees.md)
  for proofs, integration metadata, supported operations and trusted boundaries.
- **Reactive graphs** — written in linen's `Reactive` monad, where each
  function applies to observables; wiring a function to a value of the wrong
  type does not compile, and a graph may only apply the declared functions.
- **Stateless incremental execution** — supply the previous JSON state and
  changed inputs; only affected functions run. An unchanged input runs nothing.
  The caller can persist the result and resume it on another warm worker.
- **Resumable producers** — a typed step emits zero or several values and
  returns a serializable continuation and future timestamp. Delayed results
  propagate through intermediate and sink nodes. The caller's scheduler drives
  wake-ups; Lun never sleeps to wait for a producer.
- **Errors stay local** — a failure is its node's outcome; its dependents are
  skipped, and the rest of the graph carries on.
- **Diagnostics where they belong** — every build message is attributed to
  the function, the graph (with its line in the program) or the project.
- **Credential separation** — outbound connectors use liaison warrants; local
  compute and graph-vault credentials are resolved only by the trusted bound
  runtime, never exposed to compiled effect values.

## Example

[`Examples/pricing`](https://github.com/typednotes/lun/tree/main/Examples/pricing) is a Lean project with an invoice's
functions (`subtotal`, `discounted`, `shipping`, `vat`, `total`, `euros`);
[`Examples/Client.lean`](https://github.com/typednotes/lun/blob/main/Examples/Client.lean) illustrates building it and feeding
this graph. The client retains returned state and sends an explicit Trace/Error
policy and organization/user/graph binding on every call. Its real local run
passes initial evaluation, incremental changes, error propagation and recovery.
The graph itself is:

```lean
do
  let lines ← input "lines" (List Pricing.Line)
  let code ← input "code" String
  let country ← input "country" String
  let sub ← subtotal lines
  let net ← discounted sub code
  let ship ← shipping net country
  let tax ← vat net country
  let due ← total net ship tax
  euros due
```

```sh
Examples/run.sh ../linen
```

```
▸ start {"code":"","country":"FR","lines":[…]}
    subtotal    6100
    discounted  6100
    shipping    490
    vat         1220
    total       7810
    euros       "€78.10"
    ran: subtotal, discounted, shipping, vat, total

▸ ship to Germany instead: {"country":"DE"}
    country     "DE"
    shipping    890
    vat         1159
    total       8149
    euros       "€81.49"
    ran: shipping, vat, total

▸ a code that does not exist: {"code":"SUMMER"}
    code        "SUMMER"
    discounted  error: unknown discount code 'SUMMER'
    shipping    skipped (discounted has no value)
    vat         skipped (discounted has no value)
    total       skipped (discounted has no value)
    euros       skipped (total has no value)
    ran: discounted

▸ a real one: {"code":"VIP"}
    code        "VIP"
    discounted  4880
    …
    ran: discounted, shipping, vat, total

▸ the same country again: nothing to do: {"country":"DE"}
    (nothing changed)
    ran: nothing
```

The transcript illustrates a run with Trace/Error granted (`ran` is read off
the functions' traces). Against a deployed lun, the client also needs that
execution envelope; point the
client at the pushed repository:
`lake exe lun-example --lun https://… --token … --repo https://github.com/typednotes/lun --commit <sha> --path Examples/pricing`.

The same stateless execution over plain HTTP:

```sh
curl -X POST $LUN/v0/builds/$BUILD/graphs/invoice \
  -H "Authorization: Bearer $LUN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"binding":{"org_id":"example-org","user_id":"example-user","graph_id":"invoice"},"policy":{"effects":["Trace","Error"],"domains":[]},"inputs":{"lines":[],"code":"","country":"FR"}}' > reply.json

jq '{state,inputs:{country:"DE"},binding:{org_id:"example-org",user_id:"example-user",graph_id:"invoice"},policy:{effects:["Trace","Error"],domains:[]}}' reply.json > request.json
curl -X POST $LUN/v0/builds/$BUILD/graphs/invoice -H "Authorization: Bearer $LUN_TOKEN" \
  -H 'Content-Type: application/json' --data-binary @request.json
# 200 {"state": {...}, "changed": [...], "nodes": [...], "nextCallAt": null}
```

## Local interactive quickstart

The small [`Examples/interactive`](Examples/interactive/README.md) folder
contains a two-function Lean project, its build declarations, and a Python
client with Rich-formatted JSON output. With [uv](https://docs.astral.sh/uv/)
installed, run from this repository:

```sh
uv run Examples/interactive/run.py                  # stdin/stdout CLI
uv run Examples/interactive/run.py --transport http # local REST server
```

Enter `double 21`, `n 8`, `name Ada`, `show`, or `quit`. The client builds a
plain folder and retains graph state; changes to `n` and `name` recompute
independent branches. Add `--demo` for a scripted run. It reuses Lun's compiled
Linen checkout; `--linen /path/to/linen` selects another checkout. The first
native build may take a few minutes.
Python version requirements and dependencies are declared inline in each script
(PEP 723); uv installs Rich automatically for the interactive example.

### Local folders and Git repositories

Both transports accept the same build declarations, with one of these sources:

```json
{"source":{"directory":"/absolute/path/to/project"},"functions":[…],"graphs":[…]}
```

Folder mode needs no Git initialization or commit. Lun copies the current
regular files, including untracked/uncommitted files, into an immutable,
content-addressed snapshot. It skips `.git`, `.lake`, `.lun` and its own work
directory. An unchanged snapshot reuses its build; edits give a new build id,
and the earlier build keeps its original behavior. Symbolic links and special
files are refused, with a limit of 10,000 entries and 64 MiB. The source folder
is left untouched. `source.path` can select a project beneath that folder.
The status reports the generated snapshot repository and commit.

For an existing Git repository, build exactly a committed tree instead:

```json
{"source":{"url":"file:///absolute/path/to/repo","branch":"main","commit":"FULL_COMMIT_HASH","path":"lean"},"functions":[…],"graphs":[…]}
```

Use `git -C /path/to/repo rev-parse HEAD` for the full commit. Git mode checks
branch ancestry and ignores working-tree edits. Folder mode's `directory`
cannot be combined with `url`, `branch`, `commit` or credentials.

The project needs a `lakefile`, `lean-toolchain` and `lake-manifest.json`, with
only Linen as a dependency. In local mode it can use a local Linen path;
folder snapshots resolve relative dependency paths against the original
project. A path dependency remains a live, trusted local checkout.

`lun cli` enables local mode automatically. For HTTP, enable it explicitly:

```sh
lake build lun
LUN_ALLOW_LOCAL=1 LUN_WORKDIR=/tmp/lun-local LUN_ID_SALT=local-dev \
  .lake/build/bin/lun serve
```

Send the same build JSON to `POST http://localhost:8080/v0/builds`. Relative
`directory` paths are refused; the folder must be accessible to the Lun process.

## CLI

```sh
lake build lun
.lake/build/bin/lun cli
```

Send one JSON object per line, using the REST method/path and an optional object
body. For example:

```json
{"method":"GET","path":"/_health"}
{"method":"POST","path":"/v0/builds/BUILD_ID/functions/double","body":{"input":21}}
```

The corresponding replies are:

```json
{"status":200,"body":"ok"}
{"status":200,"body":{"output":42}}
```

All REST operations are available, including stateless graph steps.
Build requests use `method:"POST"`,
`path:"/v0/builds"`, and the build specification as `body`. CLI builds wait
until ready (`200`) or failed (`422`, with diagnostics). Add `"wait":false`
to submit asynchronously and poll their status. Plain-text health/log replies
are JSON strings in `body`.

Stdout contains only JSON-line replies; startup and request diagnostics use
stderr. Blank lines are ignored. A malformed command produces a `400` reply
and processing continues. Exit status is `1` if any command received a status
of `400` or above, otherwise `0`; invalid CLI arguments return `2`. Per-node
function/graph errors remain outcomes in the API body. EOF drains background
builds, closes driver workers, and exits.

CLI mode defaults to `.lun/` for builds and stores a generated id
salt there, so later CLI invocations can reuse builds. The caller sends saved
graph state on subsequent invocations. All normal
`LUN_*` runtime settings apply, including `LUN_WORKDIR`, timeouts and
`LUN_LIAISON_SDK_PATH`; the local stdin process does not require a bearer token.
One running Lun process owns a work directory at a time. To switch an existing
CLI work directory to HTTP, set `LUN_WORKDIR` to that directory and
`LUN_ID_SALT` to the contents of its `id-salt` file.

`lun serve` (also the default when no arguments are given) runs the HTTP REST
service described below. `lun --help` summarizes the two modes.

## Functions and graphs

- **A function** is a function of the project under a name and a declared
  signature: `α₁ → … → αₙ → Eff effs β`. Each argument is a JSON value (a
  `Lean.FromJson` type), or `Unit` for none; the result is linen's effect
  monad `Eff` over a row of effects, producing a JSON value (`Lean.ToJson`).
  The row is the function's effect whitelist.
- **A producer** adds `producer:true` to its declaration. Its signature ends in
  `Nat → Option S → Eff effs (List β × S × Option Nat)` after the graph arguments.
  The executor supplies the current time and continuation; each emitted `β`
  becomes a graph value. State/result JSON decoders and effect runners are audited
  like ordinary functions. See the [producer and scheduler recipe](docs/user-guide.md#9-stateless-execution-persistence-and-scheduling).
- **A graph** is a program in linen's `Reactive` monad (`Control.Reactive`,
  using the coordinated Linen runtime APIs): named `input`s, and functions applied to observables (each
  application is a `combineLatest` over the function). A function can be
  applied any number of times; a graph is acyclic by construction.

In signatures and graphs, `Control.Monad.Effect` is open (so `Eff`,
`Trace.Trace`, `Error.Error`, `HTTP.HTTP`, `FileSystem.FileSystem`), and in
graphs `Control.Reactive`, `input` and the functions by name.

## What is checked

A build fails, with diagnostics attributed to the function, graph (with its
line in the program) or project concerned, unless:

- for Git sources, the repository's `commit` is on `branch`;
- the project has a `lakefile`, a `lean-toolchain` and a `lake-manifest.json`
  that depends on **linen only**, committed for Git sources or captured in
  the snapshot for local folders;
- each declared function **is** a Lean function of its declared signature (up
  to definitional unfolding; implicit arguments, e.g. a polymorphic effect
  row, are instantiated by it; no coercion), non-dependent, ending in `Eff`,
  and:
  - every effect in its row is one of the eight supported effects, interpreted
    by the canonical bounded `Handler _ Execution` instance;
  - the transitive executable closure, including JSON dictionaries, does not
    use project unsafe/extern/implemented-by definitions, axioms, initializers,
    custom runners, raw IO or `sorry`;
- each graph builds its nodes only through `input` and the declared functions
  (its definition is walked through every non-library constant it reaches;
  the graph builder's primitives are refused), does not depend on `sorry`,
  and consists only of inputs, each named once, and applications of declared
  functions with their arity — linen's other operators are refused. Every
  function in the graph is replaced by the declared function it names before
  it runs.

Caller-owned `outputType`, `inputTypes` and ordered named `dependencies` add
independent constraints to generated declarations. `OutputContract`,
`WiringContract` and `SourceContract` are kernel-checked result, named-argument
and source contracts, not merely compiler lint. Runtime `BoundWiring` and
`BoundSources` consume equality with the actual graph, and constrained source
constructors/decoders carry type evidence. Shape/closure auditing and canonical
implementation rebinding complement these proofs. The app supplies source types
keyed by configured input name and registers historic inputs with
`recoverInputs:true`; incompatible values become source errors until edited.
See [runtime guarantees](https://github.com/typednotes/lun/blob/main/docs/runtime-guarantees.md) for the precise proof scope
and trusted boundaries.

Signatures and graph programs are Lean text, parsed as exactly one term each
(they are embedded as raw string literals, never spliced as code).

## HTTP API

| Route | |
|---|---|
| `GET /_health` | `200 ok` |
| `POST /v0/builds` | submit a build; `202` + status while it runs, `200` if that build is already ready |
| `GET /v0/builds/{id}` | status: `state` (`queued`, `fetching`, `building`, `ready`, `failed`), `error`, `diagnostics`, and once ready `functions` and `graphs` (each graph's inputs, nodes, sources and sinks) |
| `GET /v0/builds/{id}/log` | the build log |
| `POST /v0/builds/{id}/functions/{name}` | call a function |
| `POST /v0/builds/{id}/graphs/{name}` | execute a stateless graph step with inputs, optional previous state and clock |

With `LUN_TOKEN` set, every route but `/_health` needs
`Authorization: Bearer {token}`. Errors are `{"error": message}`.

### Build request

```jsonc
{
  "source": {
    "url": "https://github.com/owner/repo",     // as for `git clone`; github.com, gitlab.com or any https host
    "branch": "main",
    "commit": "0123…cdef",                       // full hash, on `branch`
    "path": "lean",                              // optional: the directory with the lakefile
    "credentials": {                             // optional: for a private github.com / gitlab.com repository
      "warrant": { … },                          // the warrant the typednotes app mints for the connection
      "account": "{user_id}/{connection_id}"
    }
  },
  "open": ["MyProject"],                         // optional: namespaces opened for signatures and graphs
  "functions": [
    { "name": "math.double", "module": "MyProject.Math",
      "function": "MyProject.Math.double", "signature": "Nat → Eff [] Nat", "outputType": "Nat" }
  ],
  "graphs": [
    { "name": "main", "program": "do\n  let x ← input \"x\" Nat\n  math.double x",
      "inputTypes": {"x": "Nat"}, "dependencies": {"math.double": ["x"]} }
  ]
}
```

The same request (same org) is the same build: submitting it again returns it.

### Functions

| Request | Response |
|---|---|
| `{"input": x}` — `x` is the value (one argument), an array of them (several), or omitted (no argument) | `{"output": y}` or `{"error": "…"}` |
| `{"inputs": [x₁, x₂, …]}` — one call each | `{"outputs": [{"output": y₁}, {"error": "…"}, …]}` |

A function's `Trace` output comes back as `"log"` (on every route).

Request examples above show input data only. Effects additionally require the
authenticated app's `binding`, `policy` and fresh function-name `connectors`
grants as described in [runtime guarantees](https://github.com/typednotes/lun/blob/main/docs/runtime-guarantees.md). Missing
policy grants no effects; generated code cannot supply private runtime credentials.

### Graphs, once

`{"inputs": {"x": 5}}` → one entry per node, in order:

```json
{"nodes": [
  {"id": 0, "input": "x", "output": 5},
  {"id": 1, "function": "seed", "args": [], "output": 10},
  {"id": 2, "function": "math.double", "args": [0], "output": 10},
  {"id": 3, "function": "add", "args": [2, 1], "error": "…"},
  {"id": 4, "function": "render", "args": [3], "skipped": 3}
]}
```

Supplied inputs are fed once; missing inputs wait. A failure stays with
its node: its dependents are `skipped`, naming their first argument without a
value, and everything else still runs.

### Stateless graph steps

`POST /v0/builds/{id}/graphs/{name}` accepts:

```json
{"state": null, "inputs": {"x": 5}, "now": 1000}
```

It returns `state`, `nodes`, ordered `changed` outcomes with `timestamp`, and
`nextCallAt`. Send the returned state with subsequent input changes or with no
inputs when a producer's wake-up is due. `now` defaults to the server's clock;
both timestamps are Unix milliseconds. `nextCallAt:null` means no timed work
remains. A timestamp equal to the state's `now` requests an immediate follow-up
to drain a large burst. Every changed intermediate and sink value is retained,
including multiple changes to the same node in one call.

The caller stores state and serializes calls to an execution. Lun stores no
execution records and exposes no session routes. Fresh authority is supplied on
each call. Unchanged inputs do not run their dependents. Multiple inputs are
fed in order; intermediate combinations can execute and appear in `changed`.
Read the [user guide](docs/user-guide.md#9-stateless-execution-persistence-and-scheduling)
for the typed producer contract and database/scheduler loop.

### Private repositories

lun never sees a credential. For a private repository it sends each host API
call to liaison (`POST /v0/egress`) with the request's warrant, exactly as the
typednotes app does; liaison checks the warrant, attaches the credential, and
relays the answer. lun speaks liaison's wire format with liaison's own module
(`Liaison.Wire`), so a warrant liaison would refuse as malformed is refused
when the build is requested. It checks the branch with the host's compare /
merge-base correspondence through the native `repositories.read` ancestry view,
then materializes complete immutable tree and per-file views through the broker.
Selectors consume private regular-file/bookkeeping witnesses; incomplete trees,
unsafe entries and oversized checkouts are refused. There is no archive,
signed-download or generic HTTP bypass. Native private repositories require
an unambiguous `[owner,repo]` and SHA-1 commits; nested GitLab namespaces and
SHA-256 native repositories are refused. Public/local repositories use `git`.

## Configuration

```sh
lake build
LUN_WORKDIR=/tmp/lun LUN_TOKEN=… LUN_LIAISON_URL=http://localhost:8080 lake exe lun
```

| Variable | Default | |
|---|---|---|
| `LUN_PORT` | `8080` | |
| `LUN_WORKDIR` | `/var/lib/lun` (`serve`), `.lun` (`cli`) | builds (`builds/{id}/`: status, log, checkout, driver) and local folder snapshots (`local/`) |
| `LUN_TOKEN` | — | bearer token for the API; unset means unauthenticated (logged loudly) |
| `LUN_LIAISON_URL` | — | liaison, for private repositories and native connector effects |
| `LUN_LIAISON_SDK_PATH` | — | local-mode-only SDK source override; generated packages otherwise require Liaison `v0.6.0` |
| `LUN_TEMP_ROOT` | `/tmp/typednotes` | temporary files, confined beneath organization/user directories |
| `LUN_BUILD_TIMEOUT` / `LUN_FETCH_TIMEOUT` / `LUN_CALL_TIMEOUT` | `3600` / `600` / `60` | seconds |
| `LUN_WORKERS` | `4` | loaded compiled workers across all builds/actors; integer 1–16; queue time is part of the call deadline |
| `LUN_PACKAGE_CACHE` | — | pre-built linen checkouts, `{cache}/linen/{rev}` |
| `LUN_ID_SALT` | random for HTTP; persisted for CLI | salt for build ids; set it for HTTP so ids (and ready builds) survive restarts |
| `LUN_ALLOW_LOCAL` | enabled by `cli` | `1`: accept folders, `file://` repositories and path dependencies for local development |

Needs `git`, Python 3, libpq development files, `elan`/`lake` and linen's native build dependencies on the
`PATH` (see the [`Dockerfile`](https://github.com/typednotes/lun/blob/main/Dockerfile)).

## Docker

Images are published to `ghcr.io/typednotes/lun` only on version tags by
[`docker-publish.yml`](https://github.com/typednotes/lun/blob/main/.github/workflows/docker-publish.yml).
Stable `vX.Y.Z` tags publish `X.Y.Z`, `X.Y` and automatic `latest` through
Docker metadata's semver rules. Prereleases publish their full version only,
without advancing `latest` or a shortened version alias. Main pushes publish no image.

[`lean_action_ci.yml`](https://github.com/typednotes/lun/blob/main/.github/workflows/lean_action_ci.yml)
runs on pushes to `main`, pull requests targeting `main`, and manual dispatch.
The user may push the release commit and its new version tag together:
`git push origin main vX.Y.Z`. The publisher's verification job has only `contents: read` and
`actions: read`; [`ci/require-main-ci.sh`](https://github.com/typednotes/lun/blob/main/ci/require-main-ci.sh)
requires the actual checkout to match the tag's commit, that commit to be
reachable from `origin/main`, and its latest **push-to-main** CI run to be
completed/success. Missing/pending CI is polled for up to two hours; failed or
cancelled runs, invalid evidence, API errors and wait timeouts block publication.
PR/manual CI and another commit's result do not qualify. After verification,
the image job checks out the verified SHA and uses `packages: write` to build
and publish, without repeating the full CI suite on tags.

```sh
docker run --rm -p 8080:8080 -v lun:/var/lib/lun \
  -e LUN_TOKEN=… -e LUN_ID_SALT=… -e LUN_LIAISON_URL=http://liaison:8080 \
  ghcr.io/typednotes/lun:latest
```

The image carries the Lean toolchain and a package cache of linen
(`LINEN_REF`, coordinated target `v1.10.0`) pre-built for what functions need, so a build
compiles only the project and its functions. To build it locally:
`docker build -t lun .` (or `podman build`).

## Development

```sh
lake test          # unit tests (#guard)
test/e2e.sh ../linen         # end to end, against coordinated sibling checkouts
uv run test/local.py        # folders, local Git, CLI/restarts and HTTP; uses the locked Linen checkout
uv run test/temporary_test.py /path/to/scratch
PATH=/path/to/postgresql/bin:$PATH uv run test/runtime.py --temp-root /path/to/scratch
```

`test/e2e.sh` turns `test/fixture` into a git repository, runs lun in local
mode, and exercises the API: builds, functions, stateless graph steps, scheduled producers, and each
refusal.
`test/local.py` additionally exercises immutable folder snapshots, edits and
build reuse, relative local dependencies, CLI protocol/error/EOF behavior,
caller-state resumption across restarts and HTTP/CLI, and committed local Git builds.

## Project status

The **0.3.0 release-preparation** suites pass the full Lun end-to-end suite and
**69 compiled-driver runtime cases**. App-provisioned local grants, source
recovery, native writer publication and adoption additionally pass the full
app → compiled Lode → real broker → local Git → compiled Lun positive/denial
pipeline. Supporting app/broker suites pass **99 API tests**, **24 browser groups**
and **655 real broker HTTP cases**.

The 0.4.0 implementation reuses bounded actor-bound compiled workers;
graphs remain declared-function applications with sequential input feeds.
Fresh execution context, correlated replies, kernel contracts and canonical
bound handlers establish the documented guarantees. Build/container isolation,
approved libraries, FFI/syscalls, database ACLs and authenticated local minting
remain trusted boundaries; Lun does not independently verify local-service HMAC
tags. Paid-provider/OAuth conformance and Linux/container verification are not
claimed by the local fixtures. See [`AGENTS.md`](https://github.com/typednotes/lun/blob/main/AGENTS.md) and
[runtime guarantees](https://github.com/typednotes/lun/blob/main/docs/runtime-guarantees.md).

## License

Licensed under the [Apache License, Version 2.0](https://github.com/typednotes/lun/blob/main/LICENSE).
