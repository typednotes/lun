# Lun v0.4.3 — parallel integration CI

The latest main CI run exceeded the end-to-end job's 90-minute limit while
compiling the producer cookbook. The build, core end-to-end suite, local
transport regressions, both interactive demonstrations and both basic cookbook
transports had already passed.

## CI

The integration workflow now runs eight independent matrix jobs: core
end-to-end tests, local transport regressions, and each CLI/HTTP transport of
the interactive demo, basic cookbook and producer cookbook. Each job has a
60-minute cold-build budget. The core job also runs the temporary-filesystem
regressions.

Matrix failures do not cancel the other suites. The existing `e2e` required
check waits for the entire matrix and fails if any suite fails, is cancelled or
is skipped. The separate `build` job continues to run the release-gate
regressions, Lean tests and example build.

## Release

Dependencies remain Linen **v1.12.0** and Liaison's pure **v0.6.0** SDK. The
runtime API and `stateless-producers-v4` contract are unchanged.

Existing tags retain their original commits and workflows. Publish the new
release commit and `v0.4.3` tag together on main. The Docker publisher requires
successful push-to-main CI on that exact commit, with its existing bounded
two-hour wait. Creating the local tag does not trigger CI or publication.
