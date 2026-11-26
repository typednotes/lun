# AGENTS.md — lun

<!-- agents-md standard v6 — github.com/ngrislain/agents. Refresh with the agents-md skill. -->

Instructions for coding agents (Claude Code, Codex, pi, opencode, …) and for humans working on
this project. `CLAUDE.md` imports this file; edit this one.

## Project

`lun` compiles a Lean project (a git repository at a commit) into typed
services: one per declared **function** (a Lean function under a declared
signature) and one per **graph** of functions (a program in linen's
`Reactive` monad). Execution is stateless: the caller supplies JSON state and
inputs, receives changed values, updated state and `nextCallAt`, persists state
in its database, and schedules further calls. Lun retains compiled code in warm
workers, never execution records. See `README.md` and `docs/user-guide.md`.
Current runner release: **Lun 0.4.3**, with Linen 1.12.0 and Liaison's pure
0.6.0 SDK. The release set below records the earlier whole-pipeline verification.
It is the runner; `lode` is the agent that writes the projects it runs —
do not confuse the two.
Coordinated release set: **Lun 0.3.0 / Lode 0.3.0 / Typednotes 0.6.0 /
Linen 1.10.0 / Liaison 0.6.0**. The current driver requires the Linen connector
APIs and Liaison's pure `Liaison.Wire` SDK; the historical 1.3.0 Reactive minimum
is not sufficient for this runtime. Package locks and image/default pins use the
current runner's dependency versions. Publishing the local release tags requires an explicit
push request; deployments still require separate explicit confirmation.

| Task | Command |
| --- | --- |
| Install | Lean toolchain from `lean-toolchain` via [elan](https://github.com/leanprover/elan); `git`, `jq`, `uv` and linen's native build dependencies (see `Dockerfile`); `lake build` fetches the dependencies pinned in `lake-manifest.json` |
| Type-check | `lake build --wfail` |
| Test | `lake test`; `lake build lun-example`; `bash ci/test-require-main-ci.sh`; `test/e2e.sh ../linen`; `uv run test/local.py`; `uv run test/temporary_test.py <scratch>`; `PATH=<postgresql>/bin:$PATH uv run test/runtime.py --temp-root <scratch>` (see Running tests and the `integration` matrix in `.github/workflows/lean_action_ci.yml`) |
| Build / release | `lake build lun`; `docker build -t lun .`; release: a `v*.*.*` tag push triggers `.github/workflows/docker-publish.yml` (push only when explicitly requested) |
| CLI (applications) | `lake exe lun --help` |

Before declaring a change done, run type-check, tests and lint, and report their real output.

## Permissions: what to do freely, when asked, and only after confirming

**Do freely** — reversible and local:
- read, search, and run type-checkers, tests, linters, formatters and local builds;
- edit files in the working tree within the scope of the task, including `docs/`, `reviews/`,
  `NOTES.md`, `TODO.md`, specs and tests;
- create scratch files in git-ignored directories (`output/`, `.cache/`, `tmp/`);
- read shell history and logs to spot repetitive work (see "Suggest automating repeated work").

**Only when the user asks** — do not initiate:
- `git commit`, creating or switching branches, stashing, rebasing a local branch;
- adding, removing or upgrading dependencies (propose the change and why);
- changing the machine outside the repository — global installs, dotfiles, symlinks, services,
  shell profiles — and recording each change in the manifest (see "Manifest of system changes");
- runs that are long (> ~10 min), costly (GPU, cluster, cloud, paid APIs) or touch shared
  resources (shared caches, staging data);
- clearing `.cache/` or `output/`, or forcing a cache refresh, when the content is slow or costly
  to produce again.

**Confirm explicitly every time**, even if a similar action was approved earlier — approval does
not carry over to a new context:
- `git push` only when explicitly requested by the user for that operation. Direct pushes to
  `main`/`master` are permitted only when explicitly specified. A request specifying the push
  scope (repositories, remote, branches and any tags), including an explicit command or batch,
  counts as confirmation; do not ask again for the same operation. Approval does not extend to
  later pushes. Never force-push or rewrite pushed history;
- opening, merging or closing a PR/MR, posting review comments, tagging, releasing, publishing a
  package or image;
- deploying to any environment (dev, staging, prod);
- publishing outside the repo: Confluence, Google Docs/Sheets, Slack, email, issue trackers;
- deleting or overwriting anything not recreated by a command in this repo: branches, remote
  resources, datasets, buckets, tables, experiment outputs;
- changing infrastructure, permissions, secrets or credentials.

**Never**: commit secrets or customer data; skip hooks (`--no-verify`); rewrite pushed history;
weaken a type-check, a test or a lint rule to make it pass; claim a check passed without running it.

## Repository layout and the documents it keeps

| Path | Audience | Content | Keep in sync with |
| --- | --- | --- | --- |
| `docs/` | humans, high level | project, architecture, algorithms, code map — a hierarchy of Markdown files illustrated with SVG figures | the code, every change |
| `README.md` (root and per package) | users and contributors, close to the code | install, usage, examples, how the code is organised | the code it sits next to |
| `SPEC.md` (per module/package) | humans first | the contract the code must fulfil | types and tests check it |
| `scripts/` | contributors | repository-maintenance helpers, including `rebase-on-main.sh` | developer workflow and tests |
| `reviews/` (git-ignored) | reviewers | reviews of commits and PRs: explanation, SVG figures, suggested comments and fixes | — (dated snapshots) |
| `output/` (git-ignored) | users of the application | large, binary or reproducible outputs of runs | — (regenerated by the CLI) |
| `.cache/` (git-ignored) | the code | cached results of slow downloads and computations | — (safe to delete) |
| `CHANGELOG.md` | users of a released artifact | one entry per version, newest on top | every release |
| `LOGBOOK.md` | humans re-running experiments | one entry per experiment, newest on top, with repeatability info | every experiment |
| `TODO.md` | everyone | planned but not executed work | when planning or finishing work |
| `NOTES.md` (anywhere) | humans and agents | things worth knowing that are not definitive documentation | when something surprising is learned |

### `docs/` — high-level documentation

- A hierarchy with an index at `docs/README.md` linking every page. Typical sections:
  `docs/project/` (goals, scope, decisions, roadmap), `docs/architecture/` (components, data
  flow, deployment), `docs/algorithms/` (methods, math, complexity, trade-offs), `docs/code/`
  (module map, key types, extension points).
- Illustrate with SVG figures stored next to the page that uses them (`docs/architecture/figures/`).
  SVG is the editable source: hand-written or generated by a committed script, legible at page
  width, in light and dark backgrounds, with a `<title>` and `<desc>`. Do not commit rendered PNGs.
- `docs/` explains *why* and *how it fits together*; `README.md` files explain *how to use and
  modify* the code next to them. Link rather than repeat; one canonical page per subject.
- Keep `docs/` in sync: a change to behaviour, architecture, an algorithm or a public interface
  updates the affected pages and figures **in the same change**. Separate measured results from
  expectations and proposals.

### `scripts/` — repository maintenance

- All runnable helpers follow the same interface standard as the application CLI:
  a colourful, structured terminal UI (plain when piped, `TERM=dumb` or `NO_COLOR` is set),
  self-documenting `--help` with examples and effective defaults plus their sources, and
  actionable errors. Missing arguments use safe defaults or prompt interactively on a TTY;
  non-interactive runs never hang waiting for input and identify any required flag explicitly.
- Keep editable defaults in a TOML file, normally `scripts/defaults.toml`, grouped by command.
  If a script manages multiple runs/sessions, organise their defaults under named TOML tables
  and select them explicitly with `--run` / `--session`; do not duplicate scripts or hard-code
  session settings. Document precedence: flags > environment > selected run/session >
  command defaults > built-in fallbacks. Help shows the resolved values and their sources.
- State-changing helpers show the resolved plan, prompt before applying it and support `--yes`
  for non-interactive use and `--dry-run` for a non-mutating preview. Defaults never bypass
  confirmation or the Permissions section.
- Git repositories keep an executable `scripts/rebase-on-main.sh`: fast-forward local `main`
  from `origin/main`, return to the original branch, and rebase it onto the updated `main`.
  Allow an explicit remote override; on `main`, only fast-forward it. In a monorepo, share one
  helper at the Git root rather than adding a copy per package.
- Provide `--help` and a non-mutating `--dry-run`. Refuse a dirty working tree (including
  untracked files), detached HEAD, and unfinished Git operations. Never stash, reset, discard
  changes or push automatically. If updating `main` fails, return to the original branch;
  if rebasing conflicts, stop there and explain `git rebase --continue` / `--abort`.
- Document how to invoke it and test it against temporary local repositories, never the working
  checkout. Preserve existing helpers rather than overwriting them blindly. Creating the helper
  is not permission to execute a rebase: the Permissions section still applies.

### `SPEC.md` — one contract per module/package

- Every module, package or component with a public surface has a `SPEC.md` beside its code: a short,
  human-readable statement of what it guarantees — purpose, inputs/outputs, invariants, error
  behaviour, performance bounds, what it explicitly does not do.
- The spec is the source of truth. Types encode as much of it as the language allows; tests check
  the rest. When code and spec disagree, fix one of them deliberately and say which.
- Number the clauses (`S1`, `S2`, …) so tests and reviews can cite them.

### `reviews/` — reviews of commits and PRs

One directory per review, `reviews/YYYY-MM-DD-<slug>/`, with a `README.md` (summary, walkthrough,
findings ranked by severity, suggested comments ready to paste, suggested fixes as diffs) and
`figures/*.svg`. A video only when the user asks for one. `reviews/` is **git-ignored**: reviews
are local working documents, not project history. Posting them anywhere requires confirmation
(see Permissions).

### `output/` — generated results, git-ignored

What an application produces that is large, not text (images, videos, models, archives, binary
tables) or reproducible from the code and its inputs goes to `output/`, which is **git-ignored**.
Organise it by command and run (`output/<command>/<run-id>/`), write next to each result what
produced it (command, parameters, commit), and make the location a CLI option with `output/` as
the default. Anything worth keeping is either reproducible from the repo (then it stays in
`output/`) or published deliberately (a release, a bucket, a document — see Permissions); small,
reviewed, hand-curated text results may be committed elsewhere, e.g. in `docs/`.

### `.cache/` — caching slow objects, git-ignored

Anything slow or costly to obtain — a large download, a long computation, a remote query — is
cached under `.cache/` (**git-ignored**), with the most idiomatic library of the language: in
Python `joblib.Memory` for function results, Parquet (or JSON for small, human-readable data) for
tables keyed by their parameters; elsewhere the equivalent (`cacache`/file caches in JS, `cached`
or file caches in Rust, …).
- The cache key covers everything that determines the result: parameters, input versions or
  checksums, and a code version. Cache only results that cannot change for a given key — never
  "the latest" of something live (pin a date, a version or a completed time window instead).
- Deleting `.cache/` must always be safe: it costs time, never correctness. Downloads are
  verified (checksum or size) before being cached.
- The CLI offers `--no-cache` and `--refresh`, and the location is configurable (config file or
  environment variable), with `.cache/` as the default.

### `CHANGELOG.md` — only if the project is released as a versioned artifact

Library, image, executable, model: one section per version, newest on top, following
[Keep a Changelog](https://keepachangelog.com) and [SemVer](https://semver.org). Unreleased changes
accumulate under `## [Unreleased]`. Bump the version and the changelog in the same change.

### `LOGBOOK.md` — only if the project runs experiments

One entry per experiment, newest on top, readable by a human who was not there: date, question,
setup, result (with numbers), conclusion, and how to repeat it — commit hash, exact command,
parameters, seeds, data snapshot, links to outputs and dashboards. Failed and inconclusive
experiments are logged too.

### `TODO.md` and `NOTES.md`

- `TODO.md`: planned but not executed work, as a checklist grouped by theme, with enough context to
  pick an item up cold. Remove items when done (the history is in git and the changelog).
- `NOTES.md`: anywhere something should be known by a human or an agent and is not definitive
  documentation — gotchas, findings, dead ends, external constraints, open questions. Promote a note
  to `docs/` or a `README.md` once it becomes definitive.

## Code

### Types: use the strongest standard checking the language offers, maximally

- Use the standard type-checker of the language/framework in its strictest practical mode, run it in
  CI, and keep it at zero errors. In this project: Lean 4 (toolchain `leanprover/lean4:v4.34.0`, pinned in `lean-toolchain`), type-checked by `lake build`, with every theorem checked by Lean's kernel. `autoImplicit` stays on (Lean's default: it only automates implicit binders, which are still fully checked), and CI builds with `--wfail` (`leanprover/lean-action@v1` `build-args` and the `lake build --wfail lun-example` step): warnings, including `declaration uses 'sorry'`, fail the build. Run `lake build --wfail` locally. "No `partial def`" remains a project convention (see Project-specific notes), not a compiler-enforced setting.
- Make illegal states unrepresentable: precise types, enums/sum types over strings and flags, new
  types for identifiers and units, immutable data by default. Avoid `Any`, casts and ignores; when
  one is unavoidable, scope it narrowly and justify it in a comment.

### Modularity and docstrings

- Organise the code in cohesive modules with explicit, minimal public interfaces and acyclic
  dependencies. One canonical implementation per concern; delete dead paths rather than keep them.
- Every public module, class and function has a docstring written for a human user: what it is
  for, how to call it, what it returns or raises, and an example when usage is not obvious. Explain
  *why* in comments, not *what*.

### One CLI per application

An application project (anything run rather than imported) exposes **a single command-line entry
point** with a short name, e.g. `uv run lun <command>` in Python (a `[project.scripts]` entry),
`npx lun`, `cargo run --bin lun`. Every operation — run, train, evaluate, serve, inspect,
publish — is a subcommand of it, not a loose script. Repository-maintenance helpers in
`scripts/` are a narrow exception, not alternative application entry points.

- **Self-documented**: `lun`, `lun --help` and `lun <command> --help` at every level list
  the commands, arguments, defaults and an example. Running a command with no arguments prints help
  rather than doing something surprising.
- **No dead ends on missing arguments**: each argument either has a default or is asked for
  interactively. Defaults live preferably in a TOML config (`lun.toml`, or `[tool.lun]` in
  `pyproject.toml`), with hard-coded fallbacks in the code; precedence is
  flag > environment variable > config file > hard-coded default, and `--help` shows the effective
  value and where it came from.
- Interactive prompts only when stdin is a TTY; otherwise (CI, agents, pipes) fail fast with a message
  naming the missing flag. Destructive or outward-facing commands ask for confirmation and accept
  `--yes` and `--dry-run`.
- **Rich, colourful terminal UI** preferably: coloured and structured help, tables, progress bars,
  spinners, syntax-highlighted output and interactive prompts/selections (Python: `rich` +
  `rich-argparse`, Typer, Textual for full TUIs; JS: `@clack/prompts`, `ink`; Rust: `clap` with
  colours, `indicatif`, `ratatui`; Go: Charm's `bubbletea`/`lipgloss`). Degrade gracefully: plain
  output when not a TTY, and honour `NO_COLOR`.
- Large, binary or reproducible results go to `output/` (overridable with `--output`); slow
  intermediate results are cached in `.cache/` (`--no-cache`, `--refresh`) — see above.
- Data goes to stdout, logs and progress to stderr; exit codes are non-zero on failure. Offer
  `--json` where the output is consumed by other programs.

### Tests

- Tests do two jobs: **illustrate** every unit and higher-level functionality working (they are
  executable examples — readable, named after the behaviour), and **check** that the code fulfils its
  `SPEC.md` (cite clause ids, e.g. `test_s3_rejects_empty_window`).
- Cover unit, integration and end-to-end levels as relevant; prefer property-based tests for
  invariants. Every bug fix comes with a regression test. Tests are deterministic and fast by default;
  slow or networked tests are marked and opt-in.

## Working style

- Keep changes focused on the task; mention unrelated issues in `TODO.md` or `NOTES.md` instead of
  fixing them silently.
- Update code, types, tests, `SPEC.md`, `docs/`, `README.md`, `CHANGELOG.md` and figures together.
- Report faithfully: what was run, what passed, what failed, what was skipped.

### Manifest of system changes

Changes to the machine outside the repository are recorded so they can be tracked and reverted:
installing or upgrading tools globally (`brew`, `uv tool`, `pipx`, `npm -g`, `cargo install`),
editing dotfiles and configuration under `$HOME`, creating symlinks, services, launch agents or
cron jobs, changing shell profiles or system settings. (Changes inside the repo are tracked by
git; cloud resources by their own infrastructure-as-code.)
- **Where**: the XDG state directory, `${XDG_STATE_HOME:-~/.local/state}/<tool>/` — an
  application uses its own name; an agent acting by hand uses `agents/`, appending one JSON
  object per line to `manifest.jsonl`:
  `{"time": "…", "project": "…", "command": "…", "changes": ["…"], "revert": "…"}`.
- **What**: the exact command, every path or setting it changed, and what reverting needs — the
  inverse command, the backup path or the previous value. Back up a file before overwriting it.
- **Applications** that make such changes (installers, linkers, setup commands) write the
  manifest themselves and offer `history` and `revert` subcommands. A revert undoes newest first,
  skips an action whose path changed since, and is itself recorded.

### Undo log for mutating actions

An application whose actions mutate state — files, configuration, links, services, databases,
anything not regenerated by a command — keeps an **undo log**: one record per mutation, enough to
revert it.
- **At the scope of what changed**, so the log sits next to the state it can restore:

  | Scope of the mutation | Undo log |
  | --- | --- |
  | system-wide (`/etc`, `/usr/local`, system services) | `/var/lib/<app>/undo.jsonl` (Linux), `/Library/Application Support/<app>/undo.jsonl` (macOS) |
  | user-wide (`$HOME`, dotfiles, user services) | `${XDG_STATE_HOME:-~/.local/state}/<app>/undo.jsonl` |
  | project or folder (files under a working directory) | `<folder>/.<app>/undo.jsonl`, git-ignored — not in `.cache/`, which must stay safe to delete |

  An action spanning several scopes writes a record in each.
- **A record** holds: id, time, the command and run it belongs to, the target (path, key, row),
  its state before (a backup path, the previous value, or "absent") and after, and the inverse
  operation. Back up anything overwritten or deleted, next to the log (`backups/<id>/`).
- **Write-ahead**: write the record *before* mutating and mark it done after, so an interrupted
  action can still be undone or completed.
- **Undo** (`<cli> undo [id|run]`, default: the latest run): newest first, only if the target
  is still in its recorded "after" state — otherwise skip and say why; the undo is itself
  logged. Backups are kept until the user prunes them (`<cli> undo --prune …`).

### Suggest automating repeated work

Look out for tasks the user does by hand again and again, and propose to automate them.
- **Where to look**: the current session (the same commands or edits requested several times);
  the shell history (`~/.zsh_history`, `~/.bash_history`), for commands touching this project;
  CI and run logs; `LOGBOOK.md`, `NOTES.md` and `README.md` steps that are long manual sequences;
  `git log` (recurring chore commits, repeated fix-ups).
- **History and logs are sensitive**: read them locally and only for this purpose, extract
  command *patterns*, and never copy secrets, tokens, hostnames of customers or personal data into
  files, messages or suggestions.
- **Suggest, don't impose**: at a natural break, propose briefly what is repeated, how often, the
  automation (preferably a subcommand of the project's CLI; otherwise a script, a git hook, a CI
  job, a scheduled job or an agent skill) and what it saves. Implement it only if the user agrees;
  note accepted-but-deferred ideas in `TODO.md`, and do not repeat a suggestion the user declined.

## Project-specific notes

### Overrides of the standard rules above

These project rules take precedence over the Permissions section above.

- **Push only when explicitly requested by the user**, following the push-specific
  confirmation rules in Permissions above. Commits are fine when asked for.

### Layout

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

### Running tests

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

### Conventions

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

### Releasing

For a new release commit, the user can push main and its version tag together.
The publisher waits up to two hours for that exact commit's latest push-to-main
CI success; all existing main CI jobs remain required. Failed/cancelled CI,
invalid evidence, API errors and timeout stop publication. Existing tags retain
their original workflows and must not be moved to adopt this behavior.

### Verified contracts and remaining boundaries

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
