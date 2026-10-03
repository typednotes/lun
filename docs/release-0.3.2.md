# Lun v0.3.2 (local implementation)

Compiled drivers and checked graph templates stay loaded in a bounded actor-bound
process cache. `LUN_WORKERS` defaults to 4 and accepts 1–16. Function and graph
entry points stay separate; graph evaluation and its explicit-state session
operations reuse the same graph template. A fixed-size Lean Vector stores only
current slots, so replacement cannot retain a chain of retired processes/pipes.

`Request.bound`/`framed`, private actor-matching leases, finite slots and
`Response.correlated` carry key/payload, capacity and response-ID evidence.
Each request constructs a fresh execution context and bounded Trace log. Grants,
private runtime configuration, session state and results are never cache entries.
The existing effect/scope/warrant checks execute on every call, including warm
workers. OS process isolation, pipe semantics, mutexes and trusted runtime/FFI
remain the execution boundary; types are not a general process sandbox.

Queue time is part of the deadline. Timeouts, malformed/uncorrelated responses
and transport failures retire the worker; a failed request is never replayed.
Idle entries may be evicted; busy entries are not evicted. A private atomically
updated parent lease makes generated drivers exit after abrupt parent death.
Graceful close retires all workers. Trace is bounded to 1 MiB per frame; transport
requests/responses are bounded to 64 MiB. Ready artifacts must attest
`bounded-eff-worker-v2`; old artifacts refuse and rebuild on resubmission.

See [throughput measurements](throughput.md). Verification includes Lean framing,
scope/correlation witnesses, real transport/cache lifecycle cases and compiled
runtime/app/writer fixtures. Linux/container verification remains CI's job.

## Source dependency and publication order

Publish Linen **v1.11.0** first, then Lun **v0.3.2**. Lun's requirement and immutable
manifest now lock that Linen tag to `a07b54b7f57534488311db673dd22248c5e6add2`.
The local tag and exact commit were fetched into Lake's dependency cache to verify
the normal locked build without unpublished-source overrides. These source refs
still require the user's publication; wait for Linen's exact-commit main CI before
publishing the dependent runtime.
Generated notebook projects may still use Linen v1.10.0: their driver template
does not import the new host-only worker transport module.

Publish the runtime image before the manually reviewed fleet rollout. App v0.10.0
also requires Lode v0.4.3 and app migration 0013. No push or deployment is performed
by this implementation batch.
