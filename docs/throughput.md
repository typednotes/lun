# Arithmetic graph benchmark: compiled process cache

The before/after sections below are historical (before `stateless-producers-v4`
replaced the session API). The current harness compares fresh `graph` calls with
`stateful` calls carrying caller-owned state; it also checks warm-worker lifecycle behavior.

Measured on 2026-10-03, macOS arm64, 16 logical CPUs, for
`Nat + Nat → Eff [] Nat`. Each run has 300 calls per mode/concurrency,
1,800 validated outputs total and zero errors. These are complete local HTTP
requests, not an addition microbenchmark or a production capacity guarantee.

## Before: spawn a driver per call

At runtime commit `c1c6ee9`, graph QPS for concurrency 1/4/8 was
**6.51 / 8.72 / 8.68**; session QPS **6.36 / 8.44 / 8.39**.
Single-client graph median/p95: **157.85 / 164.64 ms**.
Compilation (27.40 s) and 20 sequential warm-up requests were excluded.
[Raw baseline](../test/benchmark-results-20261003.json).

## After: four loaded workers

The local 0.3.2 working tree uses `bounded-eff-worker-v2` and `LUN_WORKERS=4`.
The result records the base commit, dirty flag and SHA-256 of the changed runtime
sources; it is not a measurement of a published tag.

- Graph QPS, concurrency 1/4/8: **562.63 / 576.73 / 2339.51**.
- Graph p50, concurrency 1/4/8: **1.79 / 1.74 / 1.85 ms**.
- Graph p95, concurrency 1/4/8: **1.86 / 1.84 / 8.86 ms**.
- Session QPS, concurrency 1/4/8: **471.84 / 1741.38 / 2066.82**.
- Session p95, concurrency 1/4/8: **2.18 / 2.53 / 8.14 ms**.

Single-client graph throughput increased about **86×**; at concurrency 8 it
increased about **269×**. Compilation (24.98 s) and 20 sequential graph warm-up
requests were excluded. [Raw cached result](../test/benchmark-cached-results-20261003.json).

The series run graph then session, each at concurrency 1/4/8. The initial
warm-up loads one worker; creation of the remaining workers is included in the
four-client graph timing. The eight-client and subsequent session series reuse
the resulting warm pool. This explains the low four-client aggregate QPS despite
its low median; it is not a steady-state scaling curve. Session QPS includes
setup/deletion, whereas latency samples cover only evaluated updates. Each client
uses an independent session and an HTTPConnection object which reconnects if needed.

## Current: stateless graph steps with caller-owned state

Measured on 2026-10-04 on the same macOS arm64 host, with four workers and
`stateless-producers-v4`. Each mode/concurrency has 100 validated calls;
400 measured results pass with zero errors. Compilation (23.58 s) and 20
sequential warm-up calls are excluded. The artifact records the dirty working
tree and exact runtime source hashes, rather than claiming a published release.
[Raw stateless result](../test/benchmark-stateless-results-20261004.json).

- Fresh graph calls, concurrency 1: median **1.54 ms**, p95 **1.63 ms**,
  **647.57 QPS**.
- Calls carrying caller-owned JSON state, concurrency 1: median **1.54 ms**,
  p95 **1.62 ms**, **638.91 QPS**.
- Caller-state calls, concurrency 4: median **1.57 ms**, p95 **1.80 ms**,
  **2,368.28 QPS** after the worker pool has warmed.

The fresh graph/concurrency-4 series includes cold starts for additional workers:
its median is 1.52 ms, but p99 is 287.80 ms and aggregate throughput is
226.77 QPS. Those cold starts remain in the data. Each caller owns an independent
state object; no execution records or session files are written by Lun. The run
also passes the abrupt-parent worker cleanup assertion.

Reproduce this smaller current run with:

```sh
uv run test/benchmark.py --temp-root /approved/scratch --requests 100 --concurrency 1 4 --worker-count 4
```

## Reproduce and lifecycle checks

```sh
uv run test/benchmark.py --temp-root /approved/scratch --requests 300 --worker-count 4
```

The script verifies every arithmetic result and asserts that driver workers stop
after terminating their parent runner. The final run passed that abrupt-parent
cleanup check. Lean and real compiled fixtures additionally verify bounded
framing/correlation, actor separation, fresh authority/trace context, timeout
retirement and no effect replay. [Cache contracts and release dependency](release-0.4.0.md).
