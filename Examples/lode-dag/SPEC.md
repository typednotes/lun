# Lode local DAG demo contract

- **S1 — Authoring.** Live mode runs Lode with the configured AI in a container.
  Scripted mode is explicit, labeled, and uses the same real tools/build/Git path.
  There is no automatic fallback. Native mode is restricted to scripted runs.
- **S2 — Scope.** Each run creates a new scratch tree, refuses existing output,
  and validates that the published source changes only `Demo/Cells.lean`.
  Caller-controlled dependency, signature, source and wiring contracts stay fixed.
  The protected library root checks exact universal arithmetic theorem types.
- **S3 — Cells.** Compilation must return `stateless-cells-v5`, exactly three
  signed local cell packages and matching pins on all computation nodes. Export
  retains manifest pins and payload hashes/lengths. Inputs remain typed sources.
- **S4 — Steps.** Calls check invoice totals 220, 330, 330, 660 and 880; identical
  input reports no changes. A wrong-type input returns 400 without replacing
  caller state. The final successful call resumes that state after a Lun restart.
- **S5 — Client.** Flags override environment, selected TOML and shipped defaults.
  Help gives effective defaults/sources. Dry-run does not create files or invoke
  engines/AI. Non-interactive mutation requires `--yes`; interactive stage pauses
  require a TTY. Colors follow TTY, NO_COLOR and TERM. Data goes to stdout.
- **S6 — Authority and lifecycle.** Only selected AI credentials enter authoring;
  keys are not CLI arguments or saved settings. Browser credential entry uses
  hidden input. The compiler container has no network; model credentials do not
  enter it. Only owned containers are stopped, unless retention was requested.
  The exported keyring is public; native temporary signing keys are removed.
- **S7 — Failure.** A failed command, timeout, refused build or incorrect result
  exits nonzero with diagnostics. No image is pulled implicitly at runtime.
  First image builds require network and may be slow. Host-native and image-native
  packages are specific to their compiled target; AI success is not deterministic.
