# Lode → local cells → invoice DAG

Read the [step-by-step guide](../../docs/lode-local-dag.md).

```sh
# Build local images; exercise the real pipeline with scripted model responses.
Examples/lode-dag/run.sh --mode scripted --build --yes
# Prompt for AI access on the client, optionally open its browser, then step through.
Examples/lode-dag/launch.command
```

The executable Bash entry point delegates orchestration to Python 3.12+.
`run.sh --help` shows flags and resolved defaults from [defaults.toml](defaults.toml).
No inference, engine access or files are needed for `run.sh --dry-run`.
The live launcher reads its key through hidden terminal input. Do not put secrets
in arguments, defaults or browser URLs.

The example compiles three signed Linen 5 cells under `/tmp`, checks totals
220 → 330 → 330 → 660 → 880, rejects a wrong-type input, and resumes caller-owned
state after a Lun restart. Scripted runs are explicitly labeled.
