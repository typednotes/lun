# Interactive Lun

A two-function Lean project and a small client using Rich to display JSON replies.
No Git setup is needed: Lun snapshots the project folder itself.

For the complete explanation and a larger cookbook, read the
[illustrated user guide](../../docs/user-guide.md).

With [uv](https://docs.astral.sh/uv/getting-started/installation/) installed,
run from the Lun repository root:

```sh
uv run Examples/interactive/run.py
```

The script builds Lun, copies `project/` into a temporary folder, points its
Linen dependency at Lun's already-built checkout, builds it through Lun's CLI,
and initializes a graph whose state the client retains. Enter:

```text
double 21
n 8
name Ada
show
quit
```

`double` calls a function directly. `n` and `name` update independent graph
inputs; the reply's `changed` contains only the affected input and function.
`show` displays the latest snapshot; `quit` or EOF ends the client.
JSON replies are indented and syntax-highlighted on stdout; prompts and build
messages go to stderr. Rich automatically omits colors when stdout is redirected.
The script declares its Python version and Rich dependency inline (PEP 723);
uv manages an isolated environment and installs the dependency automatically.

Use the identical interaction over a local HTTP REST server:

```sh
uv run Examples/interactive/run.py --transport http
```

Run a repeatable demonstration without prompts:

```sh
uv run Examples/interactive/run.py --demo
uv run Examples/interactive/run.py --transport http --demo
```

`--linen /absolute/path/to/linen` selects another coordinated Linen checkout.
The first native build can take a few minutes. All temporary projects, builds
created by this client are removed when it exits. Execution state belongs to
the client; Lun has no session registration or storage.

## Use the protocol directly

`build.json` contains the function and graph declarations. Replace its
`source.directory` with the absolute path of `project/` (or your own folder).
The standalone project pins Linen and contains a lock file; the interactive
client uses a local dependency to reuse the compiled library.

With `jq` installed:

```sh
jq -c --arg dir "$PWD/Examples/interactive/project" \
  '{method:"POST",path:"/v0/builds",body:(.source={directory:$dir})}' \
  Examples/interactive/build.json | .lake/build/bin/lun cli
```

The build reply contains `body.id`. Send further JSON lines to `lun cli`:

```json
{"method":"POST","path":"/v0/builds/BUILD_ID/functions/double","body":{"input":21}}
```

The reply is `{"status":200,"body":{"output":42}}`. CLI mode stores builds
in `.lun/` by default and persists its salt, so a subsequent CLI invocation
can call the same build. Set `LUN_LIAISON_SDK_PATH` to Lun's
`.lake/packages/liaison` to reuse the locked SDK locally.
