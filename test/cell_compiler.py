"""Run local tests/examples with an isolated, disposable compiler signing key.

Usage: python3 test/cell_compiler.py -- test/e2e.sh ../linen
The key and public keyring live only in a temporary directory. No user keyring
or machine configuration is changed. These keys are for local fixtures only.
"""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import tempfile


@contextmanager
def compiler_environment():
    """Yield fixture compiler settings and clean up the owned signing agent."""
    # Keep GnuPG's Unix-domain socket name within the macOS length limit.
    with tempfile.TemporaryDirectory(prefix="lun-cell-", dir="/tmp") as temp:
        directory = Path(temp)
        home = directory / "keys"
        home.mkdir(mode=0o700)

        def gpg(*args):
            result = subprocess.run(
                ["gpg", "--no-options", "--homedir", str(home), "--batch", *args],
                capture_output=True, timeout=30,
            )
            if result.returncode:
                raise RuntimeError(result.stderr.decode(errors="replace"))
            return result.stdout

        try:
            gpg("--passphrase", "", "--quick-generate-key",
                "Lun fixture compiler <compiler@lun.example>", "ed25519", "sign", "1d")
            listing = gpg("--with-colons", "--list-secret-keys").decode()
            fingerprint = next(line.split(":")[9] for line in listing.splitlines()
                               if line.startswith("fpr:"))
            keyring = directory / "compiler.gpg"
            keyring.write_bytes(gpg("--export", fingerprint))
            yield {"LUN_CELL_SIGNING_KEY": fingerprint, "LUN_CELL_SIGNING_HOME": str(home),
                   "LUN_CELL_KEYRING": str(keyring)}
        finally:
            subprocess.run(["gpgconf", "--homedir", str(home), "--kill", "gpg-agent"],
                           capture_output=True, timeout=10, check=False)


def main():
    """Run exactly the supplied command using disposable fixture keys."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("provide a command after --")
    with compiler_environment() as settings:
        return subprocess.call(command, env=dict(os.environ, **settings))


if __name__ == "__main__":
    raise SystemExit(main())
