# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 0.4.4 are described in their git tags and in `docs/release-*.md`.

## [Unreleased]

## [0.4.8] — 2026-11-27

### Changed

- Build with [Linen 5.0.0](https://github.com/typednotes/linen/releases/tag/v5.0.0).

## [0.4.7] — 2026-11-27

### Changed

- Update the Linen dependency to [4.1.0](https://github.com/typednotes/linen/releases/tag/v4.1.0).

## [0.4.6] — 2026-11-27

### Changed

- Upgrade the runner, image cache, and runnable examples to Linen 4.0.0 at its [release commit](https://github.com/typednotes/linen/commit/037925bc5068c54efd86690b78b258b9c6787959).
- Restored Lean’s default implicit binders. CI continues to reject compiler warnings.

### Fixed

- Retain Lean’s assertion symbol in generated macOS drivers so compiled
  project modules can load.

## [0.4.4] — 2026-11-17

### Changed

- Builds are stricter: implicit auto-bound variables are disabled and CI treats
  every compiler warning as an error. No runtime or API change.
