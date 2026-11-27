# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 0.4.4 are described in their git tags and in `docs/release-*.md`.

## [Unreleased]

### Added

- DAG computations execute compiler-signed native cell packages through Linen's
  owned workers, with manifest pins, independent source/ABI/codec checks, typed
  native result decoding and fresh authority. Caller-owned state binds cell pins;
  all packages are admitted before effects and workers are reaped per graph step.
- Operator compiler signing configuration and disposable local signing fixtures.
- Illustrated Lode-to-local-cells guide and colorful `/tmp` DAG shell demo,
  with client browser/hidden-key prompts, explicit scripted rehearsal, signed
  package export and caller-state restart checks. Opt-in `cell-demo` image target.

### Changed

- Build with [Linen 5.0.0](https://github.com/typednotes/linen/commit/bcfec9a81d6e738ecb273f89e2102b4712d8e160).
- Upgrade Linen to 4.1.0; align CI/image/example pins and example Lean toolchains.
- Strip non-runtime ELF symbols when linking Linux drivers to keep native cell
  payloads within Linen's 128 MiB bound; retain loader/dynamic symbols.
- Native DAG artifacts use `stateless-cells-v5`; rebuild legacy artifacts and
  start fresh graph state. Result types require `FromJson` as well as `ToJson`.
  A graph supports at most 16 distinct native cells.

- `autoImplicit` is back to Lean's default (on): it automates implicit binders,
  which are still fully checked, so it is not a weakening (agents-md standard v4).
  Warnings still fail the build (`lake build --wfail`).

## [0.4.4] — 2026-11-17

### Changed

- Builds are stricter: implicit auto-bound variables are disabled and CI treats
  every compiler warning as an error. No runtime or API change.
