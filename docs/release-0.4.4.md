# Lun v0.4.4 — strict type checking

Released on the user's request: agent instructions and strict type checking only;
no user-visible change. The runtime API, the `stateless-producers-v4` contract
and the dependencies (Linen **v1.12.0**, Liaison's pure **v0.6.0** SDK) are
unchanged.

## Changes

- `lakefile.lean` turns `autoImplicit` and `relaxedAutoImplicit` off for the
  package, and CI builds with `--wfail` (the lean-action build and the
  `lake build --wfail lun-example` step): any warning, including
  `declaration uses 'sorry'`, fails the build. The library already satisfied
  both settings; one test example (`WorkerCacheTest`) gained the `n : Nat`
  parameter it had auto-bound.
- `AGENTS.md` follows the agents-md standard v3; the "never run `git push`"
  override remains.

## Verification

Locally (macOS): `lake build --wfail`, `lake build --wfail LunTest`,
`lake build --wfail lun-example` and `lake test` passed with no warnings; the
offline release-gate regressions (50 cases) and `test/temporary_test.py`
passed. `test/e2e.sh` against Lun's locked Linen v1.12.0 passed its first 43
checks, then stopped when the machine's disk filled during a fixture build
(a failed dependency download, not a Lun result); the CI `integration` matrix
runs the full suites, cookbook and interactive demos.

## Publication

The release commit and annotated `v0.4.4` tag are prepared locally; publication
is the user's action. Push main and `v0.4.4` together; the image publisher waits
for that exact commit's main CI. Existing tags remain immutable.
