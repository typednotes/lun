#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["rich>=13"]
# ///

"""Run and verify the user-guide cookbook against a real compiled Lun project."""
import argparse
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from rich.console import Console

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT))
from Examples.interactive.run import Client  # noqa: E402


def prepare_project(destination, linen):
    """Make a fresh local project that reuses the coordinated Linen checkout."""
    destination = Path(destination).resolve()
    shutil.copytree(HERE / "project", destination, ignore=shutil.ignore_patterns(".lake", ".lun"))
    (destination / "lakefile.toml").write_text(
        'name = "lun_guide"\ndefaultTargets = ["Tutorial"]\n\n'
        '[[require]]\nname = "linen"\npath = ' + json.dumps(str(Path(linen).resolve())) + '\n\n'
        '[[lean_lib]]\nname = "Tutorial"\n'
        '\n[[lean_lib]]\nname = "Producers"\n'
    )
    subprocess.run(["lake", "update"], cwd=destination, check=True, stdout=sys.stderr, stderr=sys.stderr)
    return destination


def build_request(project, producers=False):
    request = json.loads((HERE / "build.json").read_text())
    request["source"] = {"directory": str(Path(project).resolve())}
    if producers:
        extra = json.loads((HERE / "producers.json").read_text())
        request["functions"].extend(extra["functions"])
        request["graphs"].extend(extra["graphs"])
    return request


def run_cookbook(client, project, console, quiet, producers=False):
    checks = 0

    def request(title, method, path, body=None, status=200, predicate=lambda body: True):
        nonlocal checks
        response = client.request(method, path, body)
        if not quiet:
            console.rule(title)
            console.print_json(data={"method": method, "path": path, "body": body})
            console.print_json(data=response)
        if response["status"] != status or not predicate(response["body"]):
            raise AssertionError(f"{title}: {json.dumps(response, ensure_ascii=False)}")
        checks += 1
        return response["body"]

    def authority(effects=("Trace", "Error"), graph="parallel", user="developer"):
        return {"binding": {"org_id": "guide", "user_id": user, "graph_id": graph},
                "policy": {"effects": list(effects), "domains": []}}

    def envelope(inputs, effects=("Trace", "Error"), graph="parallel", user="developer", **fields):
        return {"inputs": inputs, **authority(effects, graph, user), **fields}

    spec = build_request(project, producers)
    built = request("Build a working folder", "POST", "/v0/builds", spec,
                    predicate=lambda body: body["state"] == "ready" and len(body["functions"]) == len(spec["functions"]))
    build = built["id"]
    base = f"/v0/builds/{build}"
    request("Reuse an identical build", "POST", "/v0/builds", spec,
            predicate=lambda body: body["id"] == build)
    request("Inspect the graph description", "GET", base,
            predicate=lambda body: next(g for g in body["graphs"] if g["name"] == "parallel")["sinks"] == [3, 4])
    request("One argument", "POST", base + "/functions/double", {"input": 21},
            predicate=lambda body: body["output"] == 42)
    request("A string result", "POST", base + "/functions/greet", {"input": "Ada"},
            predicate=lambda body: body["output"] == "Hello, Ada!")
    request("No JSON argument for Unit", "POST", base + "/functions/seed", {},
            predicate=lambda body: body["output"] == 10)
    request("Instantiate a polymorphic effect row", "POST", base + "/functions/succ", {"input": 41},
            predicate=lambda body: body["output"] == 42)
    request("A list is one argument", "POST", base + "/functions/sum", {"input": [1, 2, 3]},
            predicate=lambda body: body["output"] == 6)
    request("Batch successes and a decoding error", "POST", base + "/functions/double", {"inputs": [1, "bad", 3]},
            predicate=lambda body: body["outputs"][0]["output"] == 2 and "error" in body["outputs"][1]
            and body["outputs"][2]["output"] == 6)
    request("Batch functions with two arguments", "POST", base + "/functions/add",
            {**authority(), "inputs": [[2, 3], [10, 20]]},
            predicate=lambda body: [r["output"] for r in body["outputs"]] == [5, 30]
            and "adding 2 and 3" in body["log"])
    request("A record argument", "POST", base + "/functions/norm1", {"input": {"x": 3, "y": -4}},
            predicate=lambda body: body["output"] == 7)
    request("An effect needs runtime permission", "POST", base + "/functions/add", {"input": [2, 3]},
            predicate=lambda body: "permission denied: Trace" in body["error"])
    request("Trace permission and two arguments", "POST", base + "/functions/add",
            {**authority(), "input": [2, 3]}, predicate=lambda body: body["output"] == 5 and "adding 2 and 3" in body["log"])
    request("Every graph node is returned", "POST", base + "/graphs/parallel", {"inputs": {"n": 5, "name": "Ada"}},
            predicate=lambda body: [n["output"] for n in body["nodes"]] == [5, "Ada", 10, "#10", "Hello, Ada!"])
    request("A missing input blocks only its branch", "POST", base + "/graphs/parallel", {"inputs": {"name": "Ada"}},
            predicate=lambda body: "output" not in body["nodes"][0] and "error" not in body["nodes"][2]
            and body["nodes"][4]["output"] == "Hello, Ada!")
    request("A graph with a constant source", "POST", base + "/graphs/seeded", envelope({"x": 5}, graph="seeded"),
            predicate=lambda body: [n["output"] for n in body["nodes"]] == [5, 10, 10, 20, "#20"])
    request("A diamond reuses a function at several nodes", "POST", base + "/graphs/diamond",
            envelope({"x": 5}, graph="diamond"),
            predicate=lambda body: [n["output"] for n in body["nodes"]] == [5, 10, 11, 20, 31, "#31"])
    snapshot = request("Initialize caller-owned state", "POST", base + "/graphs/parallel", envelope({"n": 5, "name": "Ada"}))
    snapshot = request("Recompute the numeric branch", "POST", base + "/graphs/parallel",
                       envelope({"n": 8}, state=snapshot["state"]),
                       predicate=lambda body: [n["id"] for n in body["changed"]] == [0, 2, 3]
                       and body["nodes"][3]["output"] == "#16")
    snapshot = request("An unchanged input emits nothing", "POST", base + "/graphs/parallel",
                       envelope({"n": 8}, state=snapshot["state"]), predicate=lambda body: body["changed"] == [])
    request("Typed input refusal", "POST", base + "/graphs/parallel",
            envelope({"n": "eight"}, state=snapshot["state"]), status=400)
    request("The caller's previous state is still usable", "POST", base + "/graphs/parallel",
            envelope({}, state=snapshot["state"]), predicate=lambda body: body["nodes"][0]["output"] == 8)
    request("An unknown input is refused", "POST", base + "/graphs/parallel",
            envelope({"typo": 1}, state=snapshot["state"]), status=400)
    request("State cannot be resumed on another graph", "POST", base + "/graphs/diamond",
            envelope({}, graph="diamond", state=snapshot["state"]), status=400)
    request("There are no session routes", "POST", base + "/graphs/parallel/sessions", {}, status=404)

    partial = request("Start with one source missing", "POST", base + "/graphs/parallel", envelope({"name": "Ada"}),
                      predicate=lambda body: "output" not in body["nodes"][0] and "error" not in body["nodes"][0])
    request("Supply the missing source later", "POST", base + "/graphs/parallel",
            envelope({"n": 5}, state=partial["state"]),
            predicate=lambda body: [n["id"] for n in body["changed"]] == [0, 2, 3])

    bad_inputs = {"p": {"x": 0, "y": 1}, "y": 2}
    request("A failing node leaves independent work running", "POST", base + "/graphs/errors", envelope(bad_inputs, graph="errors"),
            predicate=lambda body: body["nodes"][2]["error"] == "x is zero" and body["nodes"][3]["skipped"] == 2
            and body["nodes"][4]["skipped"] == 3 and body["nodes"][5]["output"] == 4)
    failed = request("Keep an error in caller-owned state", "POST", base + "/graphs/errors", envelope(bad_inputs, graph="errors"))
    request("Recover from the error", "POST", base + "/graphs/errors",
            envelope({"p": {"x": 3, "y": -4}}, graph="errors", state=failed["state"]),
            predicate=lambda body: [n["id"] for n in body["changed"]] == [0, 2, 3, 4]
            and body["nodes"][4]["output"] == "#9")

    capped = request("Start a saturating function", "POST", base + "/graphs/capped", envelope({"x": 8}, graph="capped"))
    request("Ran is different from changed", "POST", base + "/graphs/capped",
            envelope({"x": 9}, graph="capped", state=capped["state"]),
            predicate=lambda body: [n["id"] for n in body["changed"]] == [0]
            and body["nodes"][1]["output"] == 5 and "clamping 9" in body["log"])

    adopted = request("Adopt an incompatible historic source", "POST", base + "/graphs/parallel",
                      envelope({"n": "old value", "name": "Ada"}, recoverInputs=True),
                      predicate=lambda body: "error" in body["nodes"][0] and body["nodes"][4]["output"] == "Hello, Ada!")
    request("Repair the adopted source", "POST", base + "/graphs/parallel",
            envelope({"n": 5}, state=adopted["state"]), predicate=lambda body: body["nodes"][3]["output"] == "#10")

    timed = request("A producer emits twice and schedules a wake-up", "POST", base + "/graphs/timed",
                    {"inputs": {"n": 10}, "now": 1000},
                    predicate=lambda body: [n["output"] for n in body["changed"] if n.get("function") == "delayed"] == [10, 11]
                    and [n["output"] for n in body["changed"] if n.get("function") == "render"] == ["#10", "#11"]
                    and body["nextCallAt"] == 121000)
    early = request("An early scheduler call performs no work", "POST", base + "/graphs/timed",
                    {"state": timed["state"], "now": 120999},
                    predicate=lambda body: body["changed"] == [] and body["nextCallAt"] == 121000)
    request("Resume two minutes later using persisted JSON", "POST", base + "/graphs/timed",
            {"state": json.loads(json.dumps(early["state"])), "now": 121000},
            predicate=lambda body: [n["output"] for n in body["changed"]] == [12, "#12"] and body["nextCallAt"] is None)

    if producers:
        def outputs(reply, name):
            return [n["output"] for n in reply["changed"] if n.get("function") == name and "output" in n]

        def script_call(title, graph, inputs=None, previous=None, now=1000, expected=(), next_at=None):
            return request(title, "POST", base + "/graphs/" + graph,
                           {"inputs": inputs or {}, "state": previous, "now": now},
                           predicate=lambda body: outputs(body, graph) == list(expected) and body["nextCallAt"] == next_at)

        tick = script_call("A pure source yields immediately", "every5s", expected=[0], next_at=6000)
        script_call("Calling before the source is due", "every5s", previous=tick["state"], now=5999, next_at=6000)
        tick = script_call("Repeat five seconds later", "every5s", previous=tick["state"], now=6000,
                           expected=[1], next_at=11000)
        script_call("A late call schedules from its actual time", "every5s", previous=tick["state"], now=90000,
                    expected=[2], next_at=95000)
        silent = script_call("Wait before the first emission", "after5s", next_at=6000)
        script_call("Resume after an initial wait", "after5s", previous=silent["state"], now=6000, expected=[42])
        script_call("Expand a list into individual emissions", "eachNow", {"xs": [1, 2, 3]}, expected=[1, 2, 3])
        script_call("Keep a whole list as one observable element", "wholeList", {"xs": [1, 2, 3]}, expected=[[1, 2, 3]])
        script_call("An empty list completes without emissions", "eachNow", {"xs": []})
        paced = script_call("Yield a batch before entering a loop", "paced", {"xs": [1, 2, 3, 4, 5, 6]},
                            expected=[1, 2], next_at=3000)
        script_call("The cursor is dormant before its wake-up", "paced", previous=paced["state"], now=2999, next_at=3000)
        paced2 = script_call("A loop resumes inside its branch", "paced", previous=json.loads(json.dumps(paced["state"])),
                             now=3000, expected=[4], next_at=4000)
        paced3 = script_call("Advance to the next selected element", "paced", previous=paced2["state"], now=4000,
                             expected=[6], next_at=5000)
        script_call("The final wait completes the loop", "paced", previous=paced3["state"], now=5000)
        restarted = script_call("New input restarts the sequential block", "paced", {"xs": [10, 20]},
                                previous=paced["state"], now=2000, expected=[10, 20], next_at=4000)
        script_call("An obsolete wake-up does not run", "paced", previous=restarted["state"], now=3000, next_at=4000)
        script_call("The new invocation finishes", "paced", previous=restarted["state"], now=4000)
        script_call("The short-list if branch", "selected", {"xs": [1, 2, 3]}, expected=[1, 2, 3])
        script_call("The long-list else branch", "selected", {"xs": [1, 2, 3, 4]}, expected=[2, 4])
        head = script_call("A match branch yields its head", "headThenTail", {"xs": [1, 2, 3]}, expected=[1], next_at=2000)
        script_call("Resume the same match branch for the tail", "headThenTail", previous=head["state"], now=2000,
                    expected=[2, 3])
        script_call("An empty match branch completes", "headThenTail", {"xs": []})
        bursts = script_call("First burst", "batches", {"xs": [1, 2, 3, 4]}, expected=[1, 2, 3, 4], next_at=3000)
        bursts = script_call("Second filtered burst", "batches", previous=bursts["state"], now=3000,
                             expected=[2, 4], next_at=4000)
        script_call("Third reversed burst", "batches", previous=bursts["state"], now=4000, expected=[3, 2, 1])
        total = script_call("A local accumulator before a wait", "runningTotal", {"xs": [2, 3, 4]},
                            expected=[2], next_at=2000)
        total = script_call("Reconstruct the local accumulator", "runningTotal", previous=total["state"], now=2000,
                            expected=[5], next_at=3000)
        total = script_call("Keep the reconstructed accumulated sum", "runningTotal", previous=total["state"], now=3000,
                            expected=[9], next_at=4000)
        script_call("Complete the accumulator's final wait", "runningTotal", previous=total["state"], now=4000)
        bounded = script_call("Continue skips a zero", "bounded", {"xs": [0, 3, 0, 5, 11, 7]},
                              expected=[3], next_at=2000)
        bounded = script_call("Continue still works after a resume", "bounded", previous=bounded["state"], now=2000,
                              expected=[5], next_at=3000)
        script_call("Break ends before eleven", "bounded", previous=bounded["state"], now=3000)
        pairs = script_call("Enter nested loops", "pairs", {"xs": [2, 3], "ys": [5, 7]}, expected=[10], next_at=1250)
        for timestamp, value in [(1250, 14), (1500, 15), (1750, 21)]:
            pairs = script_call("Resume nested loop variables", "pairs", previous=pairs["state"], now=timestamp,
                                expected=[value], next_at=timestamp + 250)
        script_call("Finish the nested loops", "pairs", previous=pairs["state"], now=2000)
        fragment = script_call("Call a reusable producer fragment", "composed", {"xs": [1, 2, 3]},
                               expected=[2], next_at=1500)
        script_call("Compose a second fragment after a wait", "composed", previous=fragment["state"], now=1500,
                    expected=[4])
        cycle = script_call("Start a block with an internal wait", "sampleCycle", expected=[0], next_at=3000)
        cycle = script_call("Resume within the same repeat cycle", "sampleCycle", previous=cycle["state"], now=3000,
                            expected=[1], next_at=8000)
        script_call("Start the next cycle five seconds after its end", "sampleCycle", previous=cycle["state"], now=8000,
                    expected=[10], next_at=10000)
        mixed = script_call("A structured emission holds a whole list", "mixed", {"xs": [1, 2, 3, 4]},
                            expected=[{"items": [1, 2, 3, 4], "whole": True}], next_at=3000)
        mixed = script_call("The same output type holds a selected item", "mixed", previous=mixed["state"], now=3000,
                            expected=[{"items": [2], "whole": False}], next_at=4000)
        mixed = script_call("Emit the next selected item", "mixed", previous=mixed["state"], now=4000,
                            expected=[{"items": [4], "whole": False}], next_at=5000)
        script_call("Finish the structured stream", "mixed", previous=mixed["state"], now=5000)
        large = request("A large script burst retains caller-owned pending emissions", "POST", base + "/graphs/eachNow",
                        {"inputs": {"xs": list(range(600))}, "now": 1000},
                        predicate=lambda body: body["nextCallAt"] == 1000 and bool(body["state"]["pending"]))
        values = outputs(large, "eachNow")
        while large["nextCallAt"] is not None:
            large = request("Drain another immediate burst step", "POST", base + "/graphs/eachNow",
                            {"state": json.loads(json.dumps(large["state"])), "now": 1000})
            values.extend(outputs(large, "eachNow"))
        if values != list(range(600)):
            raise AssertionError("large script burst lost or reordered emissions")

    files = {"input": "hello", **authority(effects=("FileSystem",))}
    request("Temporary files need permission", "POST", base + "/functions/writeRead", {"input": "hello"},
            predicate=lambda body: "permission denied: FileSystem" in body["error"])
    request("Write and read a bound temporary file", "POST", base + "/functions/writeRead", files,
            predicate=lambda body: body["output"] == "hello")
    request("Another user has a different temporary directory", "POST", base + "/functions/readNote",
            authority(effects=("FileSystem",), user="another"), predicate=lambda body: "error" in body)
    request("HTTP requires a domain grant too", "POST", base + "/functions/fetch", authority(effects=("HTTP",)),
            predicate=lambda body: "error" in body)
    request("Native connectors need a fresh grant", "POST", base + "/functions/report",
            {"input": ["reports", "invoice.json"], **authority(effects=("Connector",))},
            predicate=lambda body: "error" in body)
    request("Static resource scope refuses before a connector operation", "POST", base + "/functions/report",
            {"input": ["private", "invoice.json"]}, predicate=lambda body: body["output"] == "static scope refused")

    # These are real compiler refusals, not JSON-parser rejections.
    wrong_output = copy.deepcopy(spec)
    wrong_output["functions"][0]["outputType"] = "String"
    request("An output contract rejects the wrong result type", "POST", "/v0/builds", wrong_output, status=422,
            predicate=lambda body: body["state"] == "failed" and len(body["diagnostics"]) > 0)
    wrong_wiring = copy.deepcopy(spec)
    wrong_wiring["graphs"][0]["dependencies"]["render"] = ["n"]
    request("A wiring contract rejects the wrong direct dependency", "POST", "/v0/builds", wrong_wiring, status=422,
            predicate=lambda body: body["state"] == "failed" and len(body["diagnostics"]) > 0)
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", choices=("cli", "http"), default="cli")
    parser.add_argument("--linen", type=Path, help="select a local Linen checkout instead of the locked dependency")
    parser.add_argument("--producers", action="store_true", help="also compile sequential scripts (requires Linen's new Producer module)")
    parser.add_argument("--prepare", type=Path, help="copy a local-Linen project to this fresh folder, then exit")
    parser.add_argument("--quiet", action="store_true", help="verify the cookbook without printing each request/reply")
    args = parser.parse_args()
    linen = args.linen or ROOT / ".lake/packages/linen"
    console = Console()
    if args.prepare:
        console.print(str(prepare_project(args.prepare, linen)), markup=False)
        return
    with tempfile.TemporaryDirectory(prefix="lun-guide-") as scratch:
        scratch = Path(scratch)
        build_command = ["lake", "build", "lun"]
        if args.producers and args.linen is not None:
            # The optional authoring module lives in the selected local checkout.
            # Build the runner and project against the same library using Lake's
            # per-invocation package override, including for unpublished refs.
            overrides = scratch / "lake-overrides.json"
            overrides.write_text(json.dumps({"version": "1.2.0", "packages": [{
                "type": "path", "scope": "", "name": "linen", "inherited": False,
                "dir": str(args.linen.resolve()), "manifestFile": "lake-manifest.json",
                "configFile": "lakefile.lean",
            }]}))
            build_command.insert(1, "--packages=" + str(overrides))
        subprocess.run(build_command, cwd=ROOT, check=True, stdout=sys.stderr, stderr=sys.stderr)
        project = prepare_project(scratch / "project", linen)
        with Client(args.transport, scratch / "work", {"LUN_TEMP_ROOT": str(scratch / "temporary")}) as client:
            checks = run_cookbook(client, project, console, args.quiet, args.producers)
        console.print(f"{checks} cookbook checks passed over {args.transport}.")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"lun guide: {error}", file=sys.stderr)
        sys.exit(1)
