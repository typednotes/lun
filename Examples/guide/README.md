# User-guide cookbook

Read the [illustrated user guide](../../docs/user-guide.md) for the explanation.
This folder holds its complete Lean project, build declarations, and a runnable
client that checks the examples against real compiled drivers.

From the Lun repository root:

```sh
uv run Examples/guide/run.py
uv run Examples/guide/run.py --transport http
```

Requests and responses use Rich-formatted JSON. Add `--quiet` to print only the
verification summary. The client uses temporary folders and reuses Lun's locked
Linen/Liaison checkouts; `--linen /path/to/linen` selects another coordinated
Linen checkout. It checks local arithmetic, decoding, batching, stateless graph
steps, delayed producers, recovery, permissions, temporary files and compile-time contract refusals. HTTP
and native connector examples exercise denial without contacting a provider.

The sequential producer extension includes fourteen compiled examples: whole
lists, individual elements, bursts, if/match branches, mutable loop locals,
nested loops, continue/break, reusable fragments, five-second sources and waits
within repeating blocks. Its helper ships in **Linen v1.12.0**:

```sh
uv run Examples/guide/run.py --producers
uv run Examples/guide/run.py --producers --transport http
```

[`project/Producers.lean`](project/Producers.lean) contains the source;
[`producers.json`](producers.json) adds its declarations to the standard build.
Add `--quiet` for only the verification summary. The scripted test clock advances
immediately, so verifying the timed examples requires no wall-clock sleeping.
For local development before publishing the dependency tag, add `--linen ../linen`.
The extension then builds both runner and project against that checkout using a
per-invocation Lake package override.

To prepare a persistent folder for the guide's manual CLI/HTTP recipes:

```sh
uv run Examples/guide/run.py --prepare /absolute/path/to/a/new/project
```

Preparation copies the example and resolves its local Linen dependency without
changing the committed project. It does not start a Lun process. Native service
prerequisites are the same as for [the interactive example](../interactive/README.md).
