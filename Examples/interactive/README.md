# Interactive Lun

A small Lean project with ordinary functions and sequential producers, and a
client using Rich to display JSON replies.
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
each [1,2,3]
whole [1,2,3]
paced [1,2,3,4,5,6]
next
next
next
tick
next tick
show main
quit
```

`double` calls a function directly. `n` and `name` update independent graph
inputs; the reply's `changed` contains only the affected input and function.
`show` displays the latest graph reply, or `show main` selects a graph by name.
`quit` or EOF ends the client. Each graph has its own state and demo clock.
JSON replies are indented and syntax-highlighted on stdout; prompts and build
messages go to stderr. Rich automatically omits colors when stdout is redirected.
The script declares its Python version and Rich dependency inline (PEP 723);
uv manages an isolated environment and installs the dependency automatically.

## Yield a list, yield elements, and wait inside a loop

The complete implementations are in [`project/Demo.lean`](project/Demo.lean).
They import `Linen.Control.Monad.Effect.Producer` and open
`Control.Monad.Effect` inside the `Demo` namespace.

**`each [1,2,3]`:** emit three individual `Nat` values immediately. The graph
wires `each` into `double`, so the downstream outputs are `2`, `4`, `6`.

**`whole [1,2,3]`:** emit the whole `List Nat` as one value. Its downstream
`sum` runs once and outputs `6`.

```lean
def each (xs : List Nat) := Producer.run do
  Producer.yieldAll xs

def whole (xs : List Nat) := Producer.run do
  Producer.yield xs
```

**`paced [1,2,3,4,5,6]`:** yield the first two elements now, wait two seconds,
then yield the even remaining elements with a one-second wait after each:

```lean
def paced (xs : List Nat) := Producer.run do
  Producer.yieldAll (xs.take 2)
  Producer.wait 2000
  for x in xs.drop 2 do
    if x % 2 == 0 then
      Producer.yield x
      Producer.wait 1000
```

The first call emits `1`, `2` at `now=1000` and requests `nextCallAt=3000`.
Successive `next` commands emit `4` at `3000`, emit `6` at `4000`, then
complete the final wait at `5000`. `double` runs on every emitted value.

**`tick`:** start a pure source that emits `0` immediately, then `1`, `2`, …
every five seconds:

```lean
def tick := Producer.every 5000 fun n => do
  Producer.yield n
```

`next tick` resumes the source at its requested timestamp. `tick` starts a
fresh counter if entered again. Change a list with another `paced [...]`
command to replace its earlier invocation and pending work; sending the same
list does not restart it.

**The demo uses an explicit clock.** `next [GRAPH]` immediately advances that
graph to its returned `nextCallAt`; it does not sleep in real time. A production
caller would omit `now` to use the real clock, persist the returned state, and
schedule the next call for that timestamp. `next` without a name uses the most
recently executed graph.
Completed graphs report that no scheduled work remains. `help` lists commands.
Read `changed` for ordered outcome changes and `nodes` for the final snapshot;
equal consecutive values still propagate but unchanged outcomes are omitted.

## CLI, HTTP, and a verified demonstration

Use the identical interaction over a local HTTP REST server:

```sh
uv run Examples/interactive/run.py --transport http
```

Run a repeatable demonstration without prompts. It checks the compiled outputs
and wake-ups for all four producers, empty lists, input replacement, and the
original function/graph examples:

```sh
uv run Examples/interactive/run.py --demo
uv run Examples/interactive/run.py --transport http --demo
```

Each transport reports `16 interactive demo checks passed` on success.
`--linen /absolute/path/to/linen` selects another coordinated Linen checkout
(Linen 1.12.0 or newer) for both the runner and project.
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
