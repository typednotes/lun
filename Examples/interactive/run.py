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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", choices=["cli", "http"], default="cli")
    parser.add_argument("--linen", type=Path, default=ROOT / ".lake/packages/linen")
    parser.add_argument("--demo", action="store_true", help="run scripted graph updates and exit")
    args = parser.parse_args()
    from rich.console import Console

    console = Console()
    subprocess.run(["lake", "build", "lun"], cwd=ROOT, check=True, stdout=sys.stderr, stderr=sys.stderr)
    with tempfile.TemporaryDirectory(prefix="lun-interactive-") as scratch:
        scratch = Path(scratch)
        project = prepare_project(scratch / "project", args.linen)
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
            snapshot = request("POST", base + "/graphs/main", {
                "inputs": {"n": 5, "name": "world"},
                "binding": {"org_id": "local", "user_id": "developer", "graph_id": "main"},
                "policy": {"effects": [], "domains": []},
            })
            print("Commands: double 21 | n 8 | name Ada | show | quit", file=sys.stderr)
            commands = iter(["double 21", "n 8", "name Ada", "show", "quit"]) if args.demo else None
            while True:
                if commands is not None:
                    line = next(commands)
                else:
                    print("lun> ", end="", file=sys.stderr, flush=True)
                    line = sys.stdin.readline()
                    if not line:
                        break
                command, _, argument = line.strip().partition(" ")
                if command == "quit":
                    break
                if command == "show":
                    console.print_json(data=snapshot, indent=2, ensure_ascii=False)
                elif command == "double":
                    try:
                        number = int(argument)
                        if number < 0:
                            raise ValueError()
                    except ValueError:
                        print("double expects a natural number", file=sys.stderr)
                        continue
                    request("POST", base + "/functions/double", {"input": number})
                elif command in ("n", "name"):
                    try:
                        value = int(argument) if command == "n" else argument
                        if isinstance(value, int) and value < 0:
                            raise ValueError()
                    except ValueError:
                        print("n expects a natural number", file=sys.stderr)
                        continue
                    snapshot = request("POST", base + "/graphs/main",
                                       {"state": snapshot["state"], "inputs": {command: value}})
                elif command:
                    print("Commands: double N | n N | name TEXT | show | quit", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"lun example: {error}", file=sys.stderr)
        sys.exit(1)
