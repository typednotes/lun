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

To prepare a persistent folder for the guide's manual CLI/HTTP recipes:

```sh
uv run Examples/guide/run.py --prepare /absolute/path/to/a/new/project
```

Preparation copies the example and resolves its local Linen dependency without
changing the committed project. It does not start a Lun process. Native service
prerequisites are the same as for [the interactive example](../interactive/README.md).
