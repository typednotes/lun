# Lun v0.4.0 — stateless resumable graph execution

This release replaces the session API with caller-owned graph state and
scheduling. The minor version changes because removing session routes and
storage is a breaking API change.

## Execution contract

`POST /v0/builds/{build}/graphs/{graph}` accepts optional previous `state`,
changed `inputs`, and an optional Unix-millisecond `now`. It returns updated
`state`, final `nodes`, every ordered `changed` outcome (including intermediate
and sink nodes), and `nextCallAt`.

The caller persists the JSON state in its database, serializes each execution,
and schedules the next invocation. `nextCallAt:null` means no timed work remains;
external input changes can still run the graph. Lun stores no execution records.

Functions declared with `producer:true` have graph arguments followed by:

```lean
Nat → Option S → Eff effs (List B × S × Option Nat)
```

A step receives the clock and optional typed continuation, emits zero or several
`B`s, and returns the new continuation and a future wake-up. New argument events
restart the producer and cancel obsolete queued values and continuations. Large
bursts retain pending work across bounded calls and request immediate follow-ups.

Source, output, wiring, effect-handler, and executable-closure checks apply to
producers as well as ordinary functions. Each request supplies fresh authority;
state never grants effect permissions or supplies private runtime configuration.
Replaying state can repeat effects, so retries/idempotency belong to the caller.

## Loaded code and local development

Compilation preloads and handshakes a driver before marking it ready, when worker
capacity is available. Its first execution binds that unused warm process to the
actor and entry point; subsequent reuse requires the exact existing binding.
`LUN_WORKERS` still defaults to four and is bounded to 1–16. Worker entries retain
compiled code and affinity metadata, not execution state or grants.

The release also includes local working-folder snapshots, the shared HTTP/CLI
operation router, `lun cli` JSON-lines requests, and runnable interactive and
user-guide cookbook clients. The [user manual](user-guide.md) explains build,
function, graph, persistence, scheduling, permission, and recovery recipes.

## Migration

- Replace session registration/updates with calls to the graph route above.
- Store `state` and `nextCallAt` in the caller's database and scheduler.
- Supply fresh binding, policy, and connector grants on input and timer calls.
- Read snapshots from the caller's storage; stop/delete an execution there.
- Initialize a new state when adopting another build, optionally using saved
  inputs with `recoverInputs:true`.

The session routes, `Lun.Session`, and the driver's session commands have been
removed. Ready drivers must attest `stateless-producers-v4`; older artifacts are
refused and must be rebuilt. Deploy callers using the new state/scheduler
contract before directing them to this runtime.

## Verification

- `lake test` and native links for Lun and the example client pass on macOS.
- The full end-to-end suite passes, including 43 compiled stateless/producer cases.
- The cookbook passes 45 checks over each of CLI and HTTP.
- Local-folder, immutable-build, restart, and cross-transport state checks pass.
- The native fixture passes 70 cases with real SCRAM queries, vault effects, and
  the HMAC broker. Its optional public-network HTTP check is not part of this run.
- The arithmetic benchmark validates 400 measured results with zero errors and
  abrupt-parent worker cleanup. Caller-state calls have a 1.54 ms median and
  1.62 ms p95 at concurrency one; see [measurements and exact source hashes](throughput.md).

Linux/container verification remains a CI axis. Controlled provider fixtures do
not establish live paid-provider or OAuth conformance.

## Dependencies and publication

The source pins remain Linen **v1.11.0** and Liaison's pure **v0.6.0** SDK. Publish
the required dependency refs before publishing this runtime. Existing release
tags retain their original commits and workflows.

The image publisher waits for successful push-to-main CI on the exact tag
commit. Local commit/tag preparation does not push or deploy; publication and
deployment remain the user's actions.
