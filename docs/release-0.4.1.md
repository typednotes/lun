# Lun v0.4.1 — sequential producer authoring

This release pairs Lun's existing caller-state producer runtime with Linen
**v1.12.0**'s pure sequential authoring helper. The graph-step API and
`stateless-producers-v4` execution contract are unchanged.

## Authoring and graph integration

- `Producer.run do ...` supports `yield`, `yieldAll`, millisecond waits,
  if/match branches, finite and nested loops, mutable pure locals, continue/break,
  and reusable sequential fragments.
- `Producer.every` repeats a finite block with a delay after each cycle. The
  saved cycle number and instruction cursor remain JSON data owned by the caller.
- The helper reconstructs earlier pure control flow to reach its cursor.
  Consumed emissions and waits are skipped; arbitrary external effects are not
  replayed by the helper. Effectful producers retain the explicit typed-step API.
- Graphs can share a public name with a declared function without Lean mistaking
  that application for recursion in the generated graph definition.
- The illustrated user guide explains Linen's `Observable` references and
  `Reactive` graph construction, then Lun's validated-DAG execution and scheduling.

## Cookbook and verification

The optional cookbook extension contains fourteen real compiled producer
examples and four new SVG illustrations. Run it over either transport:

```sh
uv run Examples/guide/run.py --producers --quiet
uv run Examples/guide/run.py --producers --transport http --quiet
```

Before publishing the dependency tag, add `--linen ../linen` to build with a
local Linen checkout. Local verification covers:

- 27 compile-time producer checks in Linen.
- Lun's unit suite and complete end-to-end suite, including 60 compiled
  caller-state cases with pure scripts, scheduling, input replacement,
  duplicate propagation, JSON persistence and bounded bursts.
- 94 cookbook checks over each of CLI and HTTP; the original 45-check cookbook
  remains available without `--producers`.
- Browser validation of the four SVGs, with no malformed XML, overflowing
  labels or overlapping text.

The Linux/container axes remain CI verification, rather than local image-build
claims. CI now also runs the sequential cookbook over both transports.

## Dependencies and publication

Lun, its example locks, CI and the image's warm package cache select Linen
**v1.12.0**. Liaison's pure SDK remains **v0.6.0**.

Publish Linen's release commit and `v1.12.0` tag before publishing Lun's release
commit and `v0.4.1` tag. Each publisher requires successful push-to-main CI for
its exact tag commit. Creating local commits and tags does not publish or deploy
either release.
