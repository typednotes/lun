#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Real local-folder, Git, CLI/restart and HTTP regressions (no third-party Python)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from Examples.interactive.run import Client, build_request, prepare_project  # noqa: E402


def git(project, *args):
    return subprocess.check_output(
        ["git", "-C", str(project), *args], text=True,
        env=dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1"),
    ).strip()


def expect(result, status, predicate=lambda body: True):
    assert result["status"] == status, result
    assert predicate(result["body"]), result
    return result["body"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--linen", type=Path, default=ROOT / ".lake/packages/linen")
    args = parser.parse_args()
    subprocess.run(["lake", "build", "lun"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="lun-local-") as scratch:
        scratch = Path(scratch).resolve()
        # Spaces, Unicode, a relative path dependency and a nested project are intentional.
        project = prepare_project(scratch / "source" / "local café" / "lean", args.linen)
        relative = os.path.relpath(args.linen.resolve(), project)
        lakefile = project / "lakefile.toml"
        lakefile.write_text(lakefile.read_text().replace(json.dumps(str(args.linen.resolve())), json.dumps(relative)))
        manifest_file = project / "lake-manifest.json"
        manifest = json.loads(manifest_file.read_text())
        manifest["packages"][0]["dir"] = relative
        manifest_file.write_text(json.dumps(manifest))
        original_manifest = manifest_file.read_bytes()
        original_source = (project / "Demo.lean").read_text()
        request = build_request(project)
        request["source"] = {"directory": str(project.parent), "path": "lean"}
        work = scratch / "work"
        env = {"LUN_ID_SALT": None}
        with Client("cli", work, env) as client:
            assert client.process is not None
            assert client.process.stdin is not None and client.process.stdout is not None
            client.process.stdin.write('not json\n{"method":"GET","path":"/_health"}\n')
            client.process.stdin.flush()
            expect(json.loads(client.process.stdout.readline()), 400)
            expect(json.loads(client.process.stdout.readline()), 200, lambda body: body == "ok")
            build = expect(client.request("POST", "/v0/builds", request), 200, lambda body: body["state"] == "ready")
            first = build["id"]
            assert not (project / ".git").exists()
            assert manifest_file.read_bytes() == original_manifest
            assert (project / "Demo.lean").read_text() == original_source
            expect(client.request("POST", f"/v0/builds/{first}/functions/double", {"input": 21}), 200,
                   lambda body: body["output"] == 42)
            expect(client.request("POST", "/v0/builds", request), 200, lambda body: body["id"] == first)
            for name in (".lake", ".git", ".lun"):
                (project / name).mkdir(exist_ok=True)
                (project / name / "ignored").write_text("bookkeeping")
            expect(client.request("POST", "/v0/builds", request), 200, lambda body: body["id"] == first)
            (project / ".git" / "ignored").unlink()
            (project / ".git").rmdir()
            # Uncommitted changes become a distinct immutable build.
            (project / "Demo.lean").write_text(original_source.replace("2 * n", "3 * n"))
            changed = expect(client.request("POST", "/v0/builds", request), 200)["id"]
            assert changed != first
            expect(client.request("POST", f"/v0/builds/{changed}/functions/double", {"input": 21}), 200,
                   lambda body: body["output"] == 63)
            expect(client.request("POST", f"/v0/builds/{first}/functions/double", {"input": 21}), 200,
                   lambda body: body["output"] == 42)
            snapshot = expect(client.request("POST", f"/v0/builds/{first}/graphs/main", {
                "inputs": {"n": 5, "name": "world"},
                "binding": {"org_id": "local", "user_id": "developer", "graph_id": "main"},
                "policy": {"effects": [], "domains": []},
            }), 200)
            snapshot = expect(client.request("POST", f"/v0/builds/{first}/graphs/main",
                                             {"state": snapshot["state"], "inputs": {"n": 8}}), 200,
                              lambda body: [node["id"] for node in body["changed"]] == [0, 2])
            saved_state = json.dumps(snapshot["state"])
            assert not (work / "sessions").exists()
            expect(client.request("POST", f"/v0/builds/{first}/graphs/main/sessions", {}), 404)
            expect(client.request("GET", f"/v0/builds/{first}/log"), 200, lambda body: isinstance(body, str))
            (project / "link.lean").symlink_to(project / "Demo.lean")
            expect(client.request("POST", "/v0/builds", request), 400,
                   lambda body: "symbolic links" in body["error"])
            (project / "link.lean").unlink()
        assert client.process is not None and client.process.returncode == 1  # errors affect exit status, not subsequent commands
        print("ok - folder snapshots, edits, reuse, relative Linen, streams and stateless updates")

        # Reopen without LUN_ID_SALT and resume caller-persisted JSON in a new worker.
        with Client("cli", work, dict(env, LUN_WORKDIR=os.path.relpath(work, ROOT))) as client:
            expect(client.request("POST", "/v0/builds", request), 200, lambda body: body["id"] == changed)
            snapshot = expect(client.request("POST", f"/v0/builds/{first}/graphs/main",
                                             {"state": json.loads(saved_state)}), 200,
                              lambda body: body["nodes"][2]["output"] == 16 and body["changed"] == [])
            expect(client.request("POST", f"/v0/builds/{changed}/functions/double", {"input": 21}), 200,
                   lambda body: body["output"] == 63)
        assert client.process is not None and client.process.returncode == 0
        print("ok - CLI restart preserves build ids and resumes caller-owned state")

        salt = (work / "id-salt").read_text()
        with Client("http", work, {"LUN_ID_SALT": salt}) as client:
            expect(client.request("POST", "/v0/builds", request), 200, lambda body: body["id"] == changed)
            expect(client.request("POST", f"/v0/builds/{changed}/functions/double", {"input": 21}), 200,
                   lambda body: body["output"] == 63)
            expect(client.request("POST", f"/v0/builds/{first}/graphs/main",
                                  {"state": snapshot["state"], "inputs": {"name": "Ada"}}), 200,
                   lambda body: [node["id"] for node in body["changed"]] == [1, 3]
                   and body["nodes"][3]["output"] == "Hello, Ada!")
        print("ok - HTTP and CLI share builds and accept the same caller-persisted state")

        with Client("http", scratch / "production", local=False) as client:
            expect(client.request("POST", "/v0/builds", request), 400,
                   lambda body: "local mode" in body["error"])
        print("ok - HTTP folder access requires explicit local mode")

        # Pinned local Git uses committed contents, while folder mode uses the working tree.
        repository = scratch / "repository"
        repository.mkdir()
        nested = prepare_project(repository / "lean", args.linen)
        (repository / ".gitignore").write_text(".lake/\n")
        git(repository, "init", "--quiet", "--initial-branch=main")
        git(repository, "add", "--all")
        git(repository, "-c", "user.name=local-test", "-c", "user.email=local@lun",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        commit = git(repository, "rev-parse", "HEAD")
        (nested / "Demo.lean").write_text(original_source.replace("2 * n", "4 * n"))
        pinned = build_request(nested)
        pinned["source"] = {"url": "file://" + str(repository), "branch": "main", "commit": commit, "path": "lean"}
        with Client("cli", work, env) as client:
            build = expect(client.request("POST", "/v0/builds", pinned), 200)["id"]
            expect(client.request("POST", f"/v0/builds/{build}/functions/double", {"input": 21}), 200,
                   lambda body: body["output"] == 42)
            # Compile an invalid working tree asynchronously: EOF must drain the build.
            (nested / "Demo.lean").write_text("this does not compile\n")
            asynchronous = expect(client.request("POST", "/v0/builds", build_request(nested), wait=False), 202)["id"]
        status = json.loads((work / "builds" / asynchronous / "status.json").read_text())
        assert status["state"] == "failed", status
        with Client("cli", work, env) as client:
            expect(client.request("POST", "/v0/builds", build_request(nested)), 422,
                   lambda body: body["state"] == "failed" and len(body["diagnostics"]) > 0)
        assert client.process is not None and client.process.returncode == 1
        print("ok - pinned local Git, EOF build draining, and compiler failure exit status")
    print("all local transport checks passed")


if __name__ == "__main__":
    main()
