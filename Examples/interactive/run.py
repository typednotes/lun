#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["rich>=13"]
# ///

"""Interactive local Lun client with Rich-formatted JSON replies."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

COMMANDS = (
    "Commands: double N | n N | name TEXT | show [GRAPH] | help | quit\n"
    "Producers: each [1,2,3] | whole [1,2,3] | paced [1,2,3,4,5,6] | tick | next [GRAPH]"
)

# The scripted demonstration verifies actual compiled outcomes and schedules.
DEMO_COMMANDS = [
    ("double 21", {"output": 42}),
    ("n 8", {"outputs": {"double": [16]}}),
    ("name Ada", {"outputs": {"greet": ["Hello, Ada!"]}}),
    ("each [1,2,3]", {"outputs": {"each": [1, 2, 3], "double": [2, 4, 6]}, "nextCallAt": None}),
    ("each []", {"outputs": {"each": [], "double": []}, "nextCallAt": None}),
    ("whole [1,2,3]", {"outputs": {"whole": [[1, 2, 3]], "sum": [6]}, "nextCallAt": None}),
    ("paced [1,2,3,4,5,6]", {"outputs": {"paced": [1, 2], "double": [2, 4]}, "nextCallAt": 3000}),
    ("next", {"outputs": {"paced": [4], "double": [8]}, "nextCallAt": 4000}),
    ("next", {"outputs": {"paced": [6], "double": [12]}, "nextCallAt": 5000}),
    ("next", {"outputs": {"paced": [], "double": []}, "nextCallAt": None}),
    ("paced [10,20]", {"outputs": {"paced": [10, 20], "double": [20, 40]}, "nextCallAt": 7000}),
    ("paced [30,40]", {"outputs": {"paced": [30, 40], "double": [60, 80]}, "nextCallAt": 7000}),
    ("next paced", {"outputs": {"paced": [], "double": []}, "nextCallAt": None}),
    ("tick", {"outputs": {"tick": [0], "double": [0]}, "nextCallAt": 6000}),
    ("next tick", {"outputs": {"tick": [1], "double": [2]}, "nextCallAt": 11000}),
    ("show main", {"outputs": {"greet": ["Hello, Ada!"]}}),
    ("quit", None),
]


class Client:
    """Own one local CLI process or HTTP server with the same API operations."""

    def __init__(self, transport, workdir, env=None, local=True):
        environment = dict(os.environ, LUN_WORKDIR=str(workdir), LUN_ID_SALT="interactive-example")
        if local:
            environment["LUN_ALLOW_LOCAL"] = "1"
        else:
            environment.pop("LUN_ALLOW_LOCAL", None)
        environment["LUN_LIAISON_SDK_PATH"] = str(ROOT / ".lake/packages/liaison")
        environment["LUN_TOKEN"] = "local-example"
        for key, value in (env or {}).items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        self.transport = transport
        self.log = tempfile.TemporaryFile(mode="w+")
        self.process = None
        try:
            if transport == "http":
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    port = listener.getsockname()[1]
                self.base = f"http://127.0.0.1:{port}"
                environment["LUN_PORT"] = str(port)
            self.process = subprocess.Popen(
                [str(ROOT / ".lake/build/bin/lun"), "cli" if transport == "cli" else "serve"],
                cwd=ROOT, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.log, text=True, bufsize=1,
            )
            if transport == "http":
                for _ in range(100):
                    try:
                        if self.request("GET", "/_health")["status"] == 200:
                            break
                    except urllib.error.URLError:
                        if self.process.poll() is not None:
                            raise RuntimeError(self.logs())
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Lun HTTP server did not become healthy\n" + self.logs())
        except BaseException:
            self.close()
            raise

    def logs(self):
        self.log.seek(0)
        return self.log.read()

    def request(self, method, path, body=None, wait=True):
        if self.transport == "cli":
            assert self.process is not None
            assert self.process.stdin is not None and self.process.stdout is not None
            command = {"method": method, "path": path, "wait": wait}
            if body is not None:
                command["body"] = body
            self.process.stdin.write(json.dumps(command) + "\n")
            self.process.stdin.flush()
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("Lun closed stdout\n" + self.logs())
            return json.loads(line)
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            self.base + path, data=data, method=method,
            headers={"Authorization": "Bearer local-example", "Content-Type": "application/json"},
        )
        try:
            response = urllib.request.urlopen(request, timeout=120)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            text = response.read().decode()
            result = {"status": response.status, "body": json.loads(text)
                      if "application/json" in response.headers.get("Content-Type", "") else text}
        if wait and method == "POST" and path == "/v0/builds" and result["status"] == 202:
            deadline = time.monotonic() + 3600
            while result["body"]["state"] not in ("ready", "failed"):
                if time.monotonic() > deadline:
                    raise TimeoutError("Lun build did not finish")
                time.sleep(0.1)
                result = self.request("GET", "/v0/builds/" + result["body"]["id"])
            if result["body"]["state"] == "failed":
                result["status"] = 422
        return result

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                if self.transport == "cli":
                    assert self.process.stdin is not None
                    self.process.stdin.close()
                else:
                    self.process.terminate()
                try:
                    self.process.wait(timeout=4200 if self.transport == "cli" else 10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            assert self.process.stdout is not None and self.process.stdin is not None
            self.process.stdout.close()
            if not self.process.stdin.closed:
                self.process.stdin.close()
        self.log.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def prepare_project(destination, linen):
    """Use the checked-out Linen build without modifying the example project."""
    shutil.copytree(HERE / "project", destination, ignore=shutil.ignore_patterns(".lake", ".lun"))
    linen = Path(linen).resolve()
    (destination / "lakefile.toml").write_text(
        'name = "lun_demo"\ndefaultTargets = ["Demo"]\n\n'
        '[[require]]\nname = "linen"\npath = ' + json.dumps(str(linen)) + '\n\n'
        '[[lean_lib]]\nname = "Demo"\n'
    )
    subprocess.run(["lake", "update"], cwd=destination, check=True, stdout=sys.stderr, stderr=sys.stderr)
    return destination


def build_request(project):
    request = json.loads((HERE / "build.json").read_text())
    request["source"] = {"directory": str(Path(project).resolve())}
    return request


def check_demo(command, reply, expected):
    """Check emissions and wake-ups from real CLI/HTTP responses."""
    for field in ("output", "nextCallAt"):
        if field in expected and reply.get(field) != expected[field]:
            raise AssertionError(f"{command}: unexpected {field}: {json.dumps(reply)}")
    for name, values in expected.get("outputs", {}).items():
        actual = [node["output"] for node in reply["changed"] if node.get("function") == name and "output" in node]
        if actual != values:
            raise AssertionError(f"{command}: {name} emitted {actual}, expected {values}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", choices=["cli", "http"], default="cli")
    parser.add_argument("--linen", type=Path, help="select a local Linen checkout instead of the locked dependency")
    parser.add_argument("--demo", action="store_true", help="verify scripted graph updates, yields and waits, then exit")
    args = parser.parse_args()
    linen = args.linen or ROOT / ".lake/packages/linen"
    from rich.console import Console

    console = Console()
    with tempfile.TemporaryDirectory(prefix="lun-interactive-") as scratch:
        scratch = Path(scratch)
        build_command = ["lake", "build", "lun"]
        if args.linen is not None:
            overrides = scratch / "lake-overrides.json"
            overrides.write_text(json.dumps({"version": "1.2.0", "packages": [{
                "type": "path", "scope": "", "name": "linen", "inherited": False,
                "dir": str(linen.resolve()), "manifestFile": "lake-manifest.json",
                "configFile": "lakefile.lean",
            }]}))
            build_command.insert(1, "--packages=" + str(overrides))
        subprocess.run(build_command, cwd=ROOT, check=True, stdout=sys.stderr, stderr=sys.stderr)
        project = prepare_project(scratch / "project", linen)
        with Client(args.transport, scratch / "work") as client:
            def request(method, path, body=None):
                result = client.request(method, path, body)
                console.print_json(data=result, indent=2, ensure_ascii=False)
                if result["status"] >= 400:
                    raise RuntimeError(json.dumps(result["body"]))
                return result["body"]

            print(f"Building the local folder through {args.transport}…", file=sys.stderr)
            build = request("POST", "/v0/builds", build_request(project))
            base = "/v0/builds/" + build["id"]
            snapshots = {}
            last_graph = "main"

            def step(graph, inputs=None, now=None, fresh=False):
                nonlocal last_graph
                previous = None if fresh else snapshots.get(graph)
                if now is None:
                    now = previous["state"]["now"] if previous else 1000
                reply = request("POST", base + "/graphs/" + graph, {
                    "state": previous["state"] if previous else None,
                    "inputs": inputs or {}, "now": now,
                    "binding": {"org_id": "local", "user_id": "developer", "graph_id": graph},
                    "policy": {"effects": [], "domains": []},
                })
                snapshots[graph] = reply
                last_graph = graph
                return reply

            step("main", {"n": 5, "name": "world"})
            print(COMMANDS, file=sys.stderr)
            print("next advances the selected graph's demo clock to nextCallAt; it does not sleep.", file=sys.stderr)
            commands = iter(DEMO_COMMANDS) if args.demo else None
            checks = 0
            while True:
                expected = None
                if commands is not None:
                    line, expected = next(commands)
                    print("lun> " + line, file=sys.stderr)
                else:
                    print("lun> ", end="", file=sys.stderr, flush=True)
                    line = sys.stdin.readline()
                    if not line:
                        break
                command, _, argument = line.strip().partition(" ")
                if command == "quit":
                    break
                reply = None
                if command == "show":
                    graph = argument.strip() or last_graph
                    if graph not in snapshots:
                        print(f"{graph} has not been initialized.", file=sys.stderr)
                        continue
                    reply = snapshots[graph]
                    console.print_json(data=reply, indent=2, ensure_ascii=False)
                elif command == "double":
                    try:
                        number = int(argument)
                        if number < 0:
                            raise ValueError()
                    except ValueError:
                        print("double expects a natural number", file=sys.stderr)
                        continue
                    reply = request("POST", base + "/functions/double", {"input": number})
                elif command in ("n", "name"):
                    try:
                        value = int(argument) if command == "n" else argument
                        if isinstance(value, int) and value < 0:
                            raise ValueError()
                    except ValueError:
                        print("n expects a natural number", file=sys.stderr)
                        continue
                    reply = step("main", {command: value})
                elif command in ("each", "whole", "paced"):
                    try:
                        values = json.loads(argument)
                        if not isinstance(values, list) or any(type(value) is not int or value < 0 for value in values):
                            raise ValueError()
                    except ValueError:
                        print(f"{command} expects a JSON list of natural numbers, e.g. [1,2,3].", file=sys.stderr)
                        continue
                    reply = step(command, {"xs": values})
                elif command == "tick":
                    if argument.strip():
                        print("tick takes no argument; use next tick to resume it.", file=sys.stderr)
                        continue
                    reply = step("tick", fresh=True)
                elif command == "next":
                    graph = argument.strip() or last_graph
                    if graph not in snapshots:
                        print(f"{graph} has not been initialized.", file=sys.stderr)
                        continue
                    next_at = snapshots[graph]["nextCallAt"]
                    if next_at is None:
                        print(f"{graph} has no scheduled work.", file=sys.stderr)
                        continue
                    print(f"Advancing {graph} to now={next_at} ms.", file=sys.stderr)
                    reply = step(graph, now=next_at)
                elif command:
                    print(COMMANDS, file=sys.stderr)
                if expected is not None:
                    if reply is None:
                        raise AssertionError(f"{line}: the demo command produced no reply")
                    check_demo(line, reply, expected)
                    checks += 1
            if args.demo:
                print(f"{checks} interactive demo checks passed over {args.transport}.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"lun example: {error}", file=sys.stderr)
        sys.exit(1)
