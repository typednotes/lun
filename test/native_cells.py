"""Native DAG admission regressions against an already compiled local build."""
import hashlib
import json
import os
import copy
import subprocess
from pathlib import Path
import sys
import urllib.error
import urllib.request


def main():
    """Tamper with owned fixture artifacts, always restoring their exact bytes."""
    base, build, work = sys.argv[1:]
    status_file = Path(work) / "builds" / build / "status.json"
    original_status = status_file.read_bytes()
    status = json.loads(original_status)
    bindings = status["cells"]
    assert bindings and all(len(cell["pin"]) == 64 for cell in bindings)
    cell = next(cell for cell in bindings if cell["name"] == "math.double")
    package = Path(cell["directory"])
    driver = Path(work) / "builds" / build / "driver" / ".lake/build/bin/lun-driver"
    # S1: Linux's static Lean symbol tables used to overflow Linen's package
    # bound. The compiler must produce an admissible native payload there too.
    assert 0 < (package / "worker").stat().st_size <= 128 * 1024 * 1024, "native cell exceeds 128 MiB"
    assert not os.path.samefile(package / "worker", driver), "package payload aliases the graph executor"
    manifest = package / "manifest.json"
    record = manifest.read_bytes()
    assert hashlib.sha256(record).hexdigest() == cell["pin"]
    assert json.loads(record)["version"] == 2

    def call(extra=None, expected=200):
        body = {"inputs": {"x": 5}, "now": 1000,
                "policy": {"effects": ["Trace", "Error"], "domains": []},
                "binding": {"org_id": "org-1", "user_id": "user-1"}}
        body.update(extra or {})
        request = urllib.request.Request(base + f"/v0/builds/{build}/graphs/main",
                                        json.dumps(body).encode(), method="POST",
                                        headers={"Authorization": "Bearer secret", "Content-Type": "application/json"})
        try:
            response = urllib.request.urlopen(request, timeout=90)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            result = json.load(response)
            assert response.code == expected, result
            return result

    good = call()
    assert good["nodes"][-1]["output"] == "#31"
    computations = [node for node in good["nodes"] if "function" in node]
    pins = {cell["name"]: cell["pin"] for cell in bindings}
    assert all(node["cell"] == pins[node["function"]] for node in computations)
    assert good["state"]["identity"]["cells"]
    # A public request cannot replace compiler pins or trusted public keys.
    spoof = call({"_cells": [], "_runtime": {"LUN_CELL_KEYRING": "/absent"}})
    assert spoof["nodes"][-1]["output"] == "#31"

    signature = package / "manifest.asc"
    original_signature = signature.read_bytes()
    try:
        signature.write_bytes(b"not a compiler signature")
        rejected = call(expected=400)
        assert "signature" in rejected["error"], rejected
        assert "log" not in rejected, rejected  # Admission precedes even seed/add Trace.
    finally:
        signature.write_bytes(original_signature)

    try:
        manifest.write_bytes(record + b"\n")
        assert "selected pin" in call(expected=400)["error"]
    finally:
        manifest.write_bytes(record)

    # All manifest variants hard-link the same multiplexed native worker.
    # Change one byte in place, restore it without copying a 100 MiB artifact.
    with (package / "worker").open("r+b") as worker:
        original = worker.read(1)
        try:
            worker.seek(0)
            worker.write(bytes([original[0] ^ 1]))
            worker.flush()
            assert "does not match" in call(expected=400)["error"]
        finally:
            worker.seek(0)
            worker.write(original)
            worker.flush()
    assert call()["nodes"][-1]["output"] == "#31"

    # S2: even correctly signed metadata must match the independently selected
    # host ABI/codecs and actual compiled source, not its own declared profile.
    def signed_metadata_refusal(change, expected):
        changed = json.loads(record)
        change(changed)
        encoded = json.dumps(changed, separators=(",", ":")).encode()
        manifest.write_bytes(encoded)
        signed = subprocess.run(
            ["gpg", "--no-options", "--homedir", os.environ["LUN_CELL_SIGNING_HOME"],
             "--batch", "--no-tty", "--pinentry-mode", "cancel", "--armor", "--detach-sign",
             "--local-user", os.environ["LUN_CELL_SIGNING_KEY"] + "!", "--output", "-"],
            input=encoded, capture_output=True, check=True, timeout=30,
        ).stdout
        signature.write_bytes(signed)
        modified_status = copy.deepcopy(status)
        next(c for c in modified_status["cells"] if c["name"] == "math.double")["pin"] = hashlib.sha256(encoded).hexdigest()
        status_file.write_text(json.dumps(modified_status))
        try:
            result = call(expected=400)
            assert expected in result["error"], result
            assert "log" not in result, result
        finally:
            manifest.write_bytes(record)
            signature.write_bytes(original_signature)
            status_file.write_bytes(original_status)

    signed_metadata_refusal(lambda m: m["runtime"].update(runtimeAbi="untrusted-abi"), "incompatible cell runtime")
    signed_metadata_refusal(lambda m: m["runtime"].update(codecSha256="0" * 64), "incompatible cell runtime")
    signed_metadata_refusal(lambda m: m["revision"]["source"].update(declaration="Fixture.other"), "different source")

    for changed_cells in ([c for c in bindings if c["name"] != "math.double"], bindings + [cell]):
        modified_status = copy.deepcopy(status)
        modified_status["cells"] = changed_cells
        try:
            status_file.write_text(json.dumps(modified_status))
            assert "exactly one pinned package" in call(expected=400)["error"]
        finally:
            status_file.write_bytes(original_status)

    # S3/S4: neither an ordinary saved outcome nor a saved pin bypasses decoding.
    state = copy.deepcopy(good["state"])
    assert state["outcomes"][3]["output"] == 10
    state["outcomes"][3]["output"] = "not a Nat"
    assert "error" in call({"state": state}, expected=400)
    state = copy.deepcopy(good["state"])
    state["identity"]["cells"][0][1] = "0" * 64
    assert "not one of this compiled graph" in call({"state": state}, expected=400)["error"]
    print("ok - native cell pins, signature/payload admission, request isolation and state binding")


if __name__ == "__main__":
    main()
