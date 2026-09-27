# lun

A runner of code with tranquility.

Compile a Lean project into typed services: one per **cell**, and one per
**DAG** of cells.

You give lun a git repository pinned at a commit, the directory of a Lean
project in it, a list of cells and some DAGs. lun fetches the project, checks
every cell's declared signature against the function it names, checks that
every DAG only wires checked cells with matching types, compiles it all, and
serves each cell and each DAG over HTTP. (The projects it runs are the ones
[`lode`](https://github.com/typednotes/lode), the agent, writes.) Built on
[`linen`](https://github.com/typednotes/linen); runs as a container (podman).

- **A cell** is a function of the project under a name and a declared
  signature: `α₁ → … → αₙ → Eff effs β`. Each argument is a JSON value (a
  `Lean.FromJson` type), or `Unit` for none; the result is linen's effect
  monad `Eff` over a row of effects, producing a JSON value (`Lean.ToJson`).
  The row is the cell's effect whitelist.
- **A DAG** is a program in linen's `Reactive` monad (`Control.Reactive`,
  linen ≥ 1.3.0): named `input`s, and cells applied to observables (each
  application is a `combineLatest` over the cell). Cells can be applied any
  number of times. A DAG is acyclic by construction, and applying a cell to
  observables of the wrong types does not compile.

```lean
do
  let x ← input "x" Nat
  let s ← seed                 -- a cell of no input (`Unit → Eff [] Nat`)
  let d ← math.double x        -- a cell applies like a function
  let a ← add d s
  render a
```

## What is checked

A build fails, with diagnostics attributed to the cell, DAG (with its line in
the program) or project concerned, unless:

- the repository's `commit` is on `branch`;
- the project has a `lakefile`, a `lean-toolchain` and a committed
  `lake-manifest.json` that depends on **linen only**;
- each cell's function **is** a function of the declared signature (up to
  definitional unfolding; implicit arguments, e.g. a polymorphic effect row,
  are instantiated by it; no coercion), non-dependent, ending in `Eff`, and:
  - every effect in its row is one of linen's `Trace`, `Error ε`, `HTTP cap`,
    `FileSystem cap`, handled by linen's own `Handler _ IO` instance (not one
    the project defines);
  - it is not `unsafe` and does not depend on `sorry`;
- each DAG builds its graph only through `input` and the declared cells (its
  definition is walked through every non-library constant it reaches; the
  graph builder's primitives are refused), does not depend on `sorry`, and its
  graph consists only of inputs, each named once, and applications of declared
  cells with their arity — linen's other operators are refused. Every function
  in the graph is replaced by the declared cell it names before it runs.

Signatures and DAG programs are Lean text, parsed as exactly one term each
(they are embedded as raw string literals, never spliced as code).

## API

| Route | |
|---|---|
| `GET /_health` | `200 ok` |
| `POST /v0/builds` | submit a build; `202` + status while it runs, `200` if that build is already ready |
| `GET /v0/builds/{id}` | status: `state` (`queued`, `fetching`, `building`, `ready`, `failed`), `error`, `diagnostics`, and once ready `cells` and `dags` (each DAG's nodes, sources and sinks) |
| `GET /v0/builds/{id}/log` | the build log |
| `POST /v0/builds/{id}/cells/{name}` | a cell's service |
| `POST /v0/builds/{id}/dags/{name}` | a DAG's service |

With `LUN_TOKEN` set, every route but `/_health` needs `Authorization: Bearer {token}`.

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
  "open": ["MyProject"],                         // optional: namespaces opened for signatures and DAGs
  "cells": [
    { "name": "math.double", "module": "MyProject.Math",
      "function": "MyProject.Math.double", "signature": "Nat → Eff [] Nat" }
  ],
  "dags": [
    { "name": "main", "program": "do\n  let x ← input \"x\" Nat\n  math.double x" }
  ]
}
```

In signatures and DAGs, `Control.Monad.Effect` is open (so `Eff`,
`Trace.Trace`, `Error.Error`, `HTTP.HTTP`, `FileSystem.FileSystem`), and in
DAGs `Control.Reactive`, `input` and the cells by name.

The same request (same org) is the same build: submitting it again returns it.

### Cell service

| Request | Response |
|---|---|
| `{"input": x}` — `x` is the value (one argument), an array of them (several), or omitted (no argument) | `{"output": y}` or `{"error": "…"}` |
| `{"inputs": [x₁, x₂, …]}` — one call each | `{"outputs": [{"output": y₁}, {"error": "…"}, …]}` |

A cell's `Trace` output comes back as `"log"`.

### DAG service

`{"inputs": {"x": 5}}` → one entry per node, in order:

```json
{"nodes": [
  {"id": 0, "input": "x", "output": 5},
  {"id": 1, "cell": "seed", "args": [], "output": 10},
  {"id": 2, "cell": "math.double", "args": [0], "output": 10},
  {"id": 3, "cell": "add", "args": [2, 1], "error": "…"},
  {"id": 4, "cell": "render", "args": [3], "skipped": 3}
]}
```

The request is one instant of the DAG's reactive graph: every input (and
every cell of no inputs) is fed once, a missing input is fed an error, and
linen runs the graph (`Graph.runM`). A failure stays with its node: its
dependents are `skipped` (naming their first argument without a value), and
everything else still runs.

### Private repositories

lun never sees a credential. For a private repository it sends each host API
call to liaison (`POST /v0/egress`) with the request's warrant, exactly as the
typednotes app does; liaison checks the warrant, attaches the credential, and
relays the answer. The warrant's caveats decide the provider, resource, run
and org of the call. lun speaks liaison's wire format with liaison's own
module (`Liaison.Wire`), so a warrant liaison would refuse as malformed is
refused when the build is requested. lun checks the branch with the host's compare /
merge-base API and downloads the commit's archive (GitHub answers with a
short-lived signed `codeload.github.com` URL, which lun fetches directly).
Public repositories are cloned with `git`.

## Running

```
lake build
LUN_WORKDIR=/tmp/lun LUN_TOKEN=… LUN_LIAISON_URL=http://localhost:8080 lake exe lun
```

| Variable | Default | |
|---|---|---|
| `LUN_PORT` | `8080` | |
| `LUN_WORKDIR` | `/var/lib/lun` | builds (`builds/{id}/`: status, log, checkout, driver) |
| `LUN_TOKEN` | — | bearer token for the API; unset means unauthenticated (logged loudly) |
| `LUN_LIAISON_URL` | — | liaison, for private repositories |
| `LUN_BUILD_TIMEOUT` / `LUN_FETCH_TIMEOUT` / `LUN_CALL_TIMEOUT` | `3600` / `600` / `60` | seconds |
| `LUN_PACKAGE_CACHE` | — | pre-built linen checkouts, `{cache}/linen/{rev}` |
| `LUN_ID_SALT` | random | salt for build ids; set it so ids (and ready builds) survive restarts |
| `LUN_ALLOW_LOCAL` | — | `1`: accept `file://` repositories and path dependencies. Tests only |

Needs `git`, `tar`, `elan`/`lake` and linen's native build dependencies on the
`PATH` (see the `Dockerfile`).

### Container

```
podman build -t lun .
podman run --rm -p 8080:8080 -v lun:/var/lib/lun \
  -e LUN_TOKEN=… -e LUN_ID_SALT=… -e LUN_LIAISON_URL=http://liaison:8080 lun
```

The image carries the Lean toolchain and a package cache of linen
(`LINEN_REF`, default `v1.5.0`) pre-built for what cells need, so a build
compiles only the project and its cells.

## Testing

```
lake build LunTests          # unit tests (#guard)
test/e2e.sh ../linen          # end to end, against a linen checkout (>= 1.3.0; CI uses v1.5.0)
```

`test/e2e.sh` turns `test/fixture` into a git repository, runs lun in local
mode, and exercises the API: builds, cells, DAGs, and each refusal.

See [`AGENTS.md`](./AGENTS.md) for the layout and the known gaps.
