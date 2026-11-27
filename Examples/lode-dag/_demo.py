"""Implementation of run.sh; all public operations still use Lode/Lun's CLIs."""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import webbrowser
from pathlib import Path
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MODEL_ENV = {"provider": "LODE_MODEL_PROVIDER", "api": "LODE_MODEL_API",
             "base_url": "LODE_MODEL_BASE_URL", "model": "LODE_MODEL_NAME"}
PUBLIC_ENV = ("PATH", "HOME", "TMPDIR", "TERM", "NO_COLOR", "LANG", "LC_ALL",
              "ELAN_HOME", "LEAN_CC", "LIBRARY_PATH", "DYLD_LIBRARY_PATH",
              "SSL_CERT_FILE", "SSL_CERT_DIR", "LEAN_NUM_THREADS")
STUB = '''import Linen.Control.Monad.Effect

open Control.Monad.Effect
namespace Demo

/-- Line amount in integer cents. -/
def subtotal (_price _quantity : Nat) : Eff [] Nat := pure 0
/-- Ten-percent tax, rounded down to integer cents. -/
def tax (_amount : Nat) : Eff [] Nat := pure 0
/-- Amount including its computed tax. -/
def total (_amount _levy : Nat) : Eff [] Nat := pure 0

end Demo
'''
IMPLEMENTATION = '''import Linen.Control.Monad.Effect

open Control.Monad.Effect
namespace Demo

/-- Line amount in integer cents. -/
def subtotal (price quantity : Nat) : Eff [] Nat := pure (price * quantity)
/-- Ten-percent tax, rounded down to integer cents. -/
def tax (amount : Nat) : Eff [] Nat := pure (amount / 10)
/-- Amount including its computed tax. -/
def total (amount levy : Nat) : Eff [] Nat := pure (amount + levy)

/-- The implementation satisfies its contract for every input. -/
theorem subtotal_correct (price quantity : Nat) :
    (subtotal price quantity).run = price * quantity := rfl
/-- Tax is exactly the specified integer calculation. -/
theorem tax_correct (amount : Nat) : (tax amount).run = amount / 10 := rfl
/-- The final amount is the sum of its two direct arguments. -/
theorem total_correct (amount levy : Nat) : (total amount levy).run = amount + levy := rfl

end Demo
'''
TASK = """Implement only Demo/Cells.lean in this local scratch repository.
Replace the three stubs: subtotal price quantity = price * quantity;
tax amount = amount / 10 (Nat division); total amount levy = amount + levy.
Keep the public names and Eff [] Nat signatures. Add kernel-checked theorems
subtotal_correct, tax_correct and total_correct saying that running each Eff
returns the specified expression for all inputs. Keep docstrings. Do not use
sorry, axioms, unsafe code, metaprograms or initializers. Do not change the
lakefile, dependency manifest, lean-toolchain, .gitignore or lun.json.
Read the file, edit it, use check until it builds, then publish to this local
branch with a clear commit message. Do not contact any remote Git repository.
"""


class DemoError(RuntimeError):
    """An actionable demo setup, process or contract failure."""


class Console:
    """Structured diagnostics; colors are disabled for pipes, NO_COLOR or dumb terminals."""

    def __init__(self) -> None:
        self.color = sys.stderr.isatty() and "NO_COLOR" not in os.environ and os.environ.get("TERM") != "dumb"

    def line(self, text: str, color: str = "36") -> None:
        decorated = f"\033[1;{color}m{text}\033[0m" if self.color else text
        print(decorated, file=sys.stderr, flush=True)

    def step(self, number: int, text: str, interactive: bool) -> None:
        if interactive and number > 1:
            input("Press Enter for the next step… ")
        self.line(f"[{number}/8] {text}")

    def passed(self, text: str) -> None:
        self.line(f"  PASS  {text}", "32")


def configuration(argv: list[str]) -> argparse.Namespace:
    """Resolve flags > environment > TOML, retaining sources for --help/--dry-run."""
    early = argparse.ArgumentParser(add_help=False)
    early.add_argument("--defaults", type=Path, default=HERE / "defaults.toml")
    selected, _ = early.parse_known_args(argv)
    data = tomllib.loads((HERE / "defaults.toml").read_text())["demo"]
    selected_data = tomllib.loads(selected.defaults.read_text())["demo"]
    if set(selected_data) - set(data):
        raise DemoError("Unknown option in the selected defaults [demo] table")
    for key, value in selected_data.items():
        if type(value) is not type(data[key]):
            raise DemoError(f"Wrong type for defaults option {key}")
    data.update(selected_data)
    sources: dict[str, str] = {}
    for key, value in list(data.items()):
        env = MODEL_ENV.get(key, "LODE_DAG_" + key.upper())
        if env in os.environ:
            raw = os.environ[env]
            if isinstance(value, bool):
                if raw.lower() not in ("true", "false", "1", "0"):
                    raise DemoError(f"{env} must be true/false or 1/0")
                data[key] = raw.lower() in ("true", "1")
            elif isinstance(value, int):
                data[key] = int(raw)
            else:
                data[key] = raw
            sources[key] = env
        else:
            origin = selected.defaults if key in selected_data else HERE / "defaults.toml"
            sources[key] = f"{origin.name} [demo]"
    parser = argparse.ArgumentParser(
        description="Lode in an image writes a /tmp Git project; Lun compiles signed local cells and steps its invoice DAG.",
        epilog="Flags > environment > selected defaults TOML. --yes is never read from defaults.\n"
               "Live inference is the default; --mode scripted is an explicitly labeled rehearsal.\n\n"
               "Examples:\n  run.sh --build --yes\n  run.sh --mode scripted --build --yes\n"
               "  run.sh --engine native --mode scripted --yes\n  run.sh --dry-run\n\n"
               "Set LODE_MODEL_API_KEY and the non-secret LODE_MODEL_PROVIDER/LODE_MODEL_NAME for live runs.\n"
               "No image is pulled implicitly. Containers and model steps are bounded; outputs use a new directory.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--defaults", type=Path, default=selected.defaults, help="TOML file with a [demo] table")
    for key, value in data.items():
        flag = "--" + key.replace("_", "-")
        kwargs: dict[str, object] = {"default": value, "help": f"effective default: {value!r} ({sources[key]})"}
        if isinstance(value, bool):
            kwargs["action"] = argparse.BooleanOptionalAction
        elif isinstance(value, int):
            kwargs["type"] = int
        if key == "engine":
            kwargs["choices"] = ("podman", "docker", "native")
        if key == "mode":
            kwargs["choices"] = ("live", "scripted")
        parser.add_argument(flag, **kwargs)
    parser.add_argument("--yes", action="store_true", help="approve the displayed plan non-interactively")
    parser.add_argument("--dry-run", action="store_true", help="show the plan without creating files, invoking AI or contacting an engine")
    options = parser.parse_args(argv)
    options.sources = {key: ("flag" if any(arg.partition("=")[0] == "--" + key.replace("_", "-") or
                         arg.partition("=")[0] == "--no-" + key.replace("_", "-") for arg in argv) else value)
                       for key, value in sources.items()}
    if options.engine not in ("podman", "docker", "native") or options.mode not in ("live", "scripted"):
        raise DemoError("Invalid engine or mode in the selected configuration; see --help")
    for key in ("max_steps", "max_tokens", "model_timeout", "run_timeout", "build_timeout", "call_timeout"):
        if getattr(options, key) <= 0:
            raise DemoError(f"--{key.replace('_', '-')} must be positive")
    if options.interactive and not sys.stdin.isatty():
        raise DemoError("--interactive needs a terminal; omit it for an automatic step-by-step run")
    if options.engine == "native" and options.mode != "scripted":
        raise DemoError("--engine native is a scripted verification path; live AI authoring uses Docker or Podman")
    if options.engine == "native" and (options.build or options.lode_container):
        raise DemoError("--engine native uses existing local binaries; --build/--lode-container apply to image runs")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", options.key_env):
        raise DemoError("--key-env must name an environment variable, not contain a key")
    if options.auth_url:
        validate_auth_url(options.auth_url)
    return options


def validate_auth_url(url: str) -> None:
    """Allow only an explicit HTTPS credential page, without embedded credentials."""
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise DemoError("The credential page must be an HTTPS URL without embedded credentials")


def prompt_model(options: argparse.Namespace, console: Console) -> None:
    """Prompt on the client terminal; open its browser and keep the key in memory."""
    if options.mode != "live" or options.lode_container:
        return
    missing = not options.provider or not options.model or not os.environ.get(options.key_env)
    if not missing or not sys.stdin.isatty():
        return
    console.line("Configure AI access locally. The API key is read with hidden input.")
    if not options.provider:
        options.provider = input("Lode provider (for example openai or anthropic): ").strip()
    if not options.model:
        options.model = input("Model name from your provider: ").strip()
    if not options.api:
        options.api = input("API protocol (Enter for provider default; e.g. responses): ").strip()
    if not os.environ.get(options.key_env):
        url = options.auth_url or input("HTTPS credential page to open in your browser (Enter to skip): ").strip()
        if url:
            validate_auth_url(url)
            if not webbrowser.open(url, new=2):
                console.line("Browser launch failed. Open the credential page yourself, then continue.", "33")
        os.environ[options.key_env] = getpass.getpass("API key (hidden; retained only for this run): ").strip()


def build_spec(repository: str, commit: str) -> dict:
    """The caller-owned function, source and ordered wiring contracts."""
    return {"source": {"url": repository, "branch": "main", "commit": commit},
            "functions": [{"name": name, "module": "Demo.Cells", "function": "Demo." + name,
                           "signature": signature, "outputType": "Nat"} for name, signature in (
                ("subtotal", "Nat → Nat → Eff [] Nat"), ("tax", "Nat → Eff [] Nat"),
                ("total", "Nat → Nat → Eff [] Nat"))],
            "graphs": [{"name": "invoice", "program": 'do\n let p ← input "price" Nat\n let q ← input "quantity" Nat\n let s ← subtotal p q\n let t ← tax s\n total s t',
                        "inputTypes": {"price": "Nat", "quantity": "Nat"},
                        "dependencies": {"subtotal": ["price", "quantity"], "tax": ["subtotal"],
                                         "total": ["subtotal", "tax"]}}]}


def session_request(repository: str, scripted: bool) -> dict:
    """Both modes use the actual Lode tools; only the model responses differ."""
    request = {"source": {"url": repository, "branch": "main"},
               "tools": ["read", "ls", "grep", "edit", "check", "publish"]}
    if scripted:
        request["model"] = {"api": "scripted", "script": [
            {"calls": [{"name": "read", "arguments": {"path": "Demo/Cells.lean"}}]},
            {"calls": [{"name": "edit", "arguments": {"path": "Demo/Cells.lean", "old": STUB, "new": IMPLEMENTATION}}]},
            {"calls": [{"name": "check", "arguments": {}}]},
            {"calls": [{"name": "publish", "arguments": {"message": "Implement and prove invoice cells"}}]},
            {"text": "Published the three checked invoice cell implementations."}]}
    return request


def public_environment() -> dict[str, str]:
    """Do not inherit unrelated credentials into native fixture processes."""
    return {name: os.environ[name] for name in PUBLIC_ENV if name in os.environ}


def command(args: list[str], *, env: dict[str, str] | None = None, input: bytes | None = None,
            timeout: int = 600, log: Path | None = None) -> bytes:
    """Run an argv vector, capture diagnostics and give failures a log path."""
    if log:
        with log.open("wb") as stream:
            result = subprocess.run(args, check=False, input=input, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        output, errors = log.read_bytes(), b""
    else:
        result = subprocess.run(args, check=False, input=input, env=env, capture_output=True, timeout=timeout)
        output, errors = result.stdout, result.stderr
    if result.returncode:
        location = f"; see {log}" if log else ": " + errors.decode(errors="replace")[-3000:]
        raise DemoError(f"{Path(args[0]).name} failed ({result.returncode}){location}")
    return output


class Runner:
    """An owned container or a private native scratch environment."""

    def __init__(self, role: str, root: str, options: argparse.Namespace, host: Path,
                 image: str = "", existing: str = "") -> None:
        self.role, self.root, self.options, self.host = role, root, options, host
        self.native = options.engine == "native"
        self.owned = not existing
        self.container = existing
        if not self.native and not existing:
            auth = host / "public-registry-auth" / "config.json"
            args = (["podman", "run", "--authfile", str(auth)] if options.engine == "podman" else
                    ["docker", "run"])
            args += ["--detach", "--rm", "--pull=never"]
            if role == "compiler":
                args += ["--network=none"]
            args += ["--entrypoint", "/bin/sleep", image, "infinity"]
            self.container = command(args).decode().strip()
        try:
            self.run(["mkdir", "-p", root])
        except Exception:
            self.close()
            raise

    def argv(self, args: list[str], env: dict[str, str] | None = None, interactive: bool = True) -> tuple[list[str], dict[str, str]]:
        environment = public_environment()
        environment.update(env or {})
        if self.native:
            return args, environment
        for name in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH",
                     "CONTAINER_HOST", "CONTAINER_CONNECTION"):
            if name in os.environ:
                environment[name] = os.environ[name]
        argv = [self.options.engine, "exec"] + (["-i"] if interactive else [])
        for name in env or {}:
            # Values travel in the CLI's environment, never command arguments.
            argv += ["--env", name]
        return argv + [self.container, *args], environment

    def run(self, args: list[str], *, env: dict[str, str] | None = None, input: bytes | None = None,
            timeout: int = 600, log: str | None = None) -> bytes:
        argv, environment = self.argv(args, env)
        return command(argv, env=environment, input=input, timeout=timeout,
                       log=self.host / log if log else None)

    def write(self, path: str, data: bytes) -> None:
        self.run(["sh", "-c", 'umask 077; mkdir -p "$(dirname "$1")"; cat > "$1"', "write", path], input=data)

    def read(self, path: str) -> bytes:
        return self.run(["cat", path])

    def upload(self, source: Path, destination: str, *, tracked: bool = False) -> None:
        self.run(["mkdir", "-p", destination])
        archive = self.host / (self.role + "-upload.tar")
        if tracked:
            archive.write_bytes(command(["git", "-C", str(source), "archive", "HEAD"]))
        else:
            with tarfile.open(archive, "w") as bundle:
                bundle.add(source, arcname=".", filter=lambda item: None if
                           any(part in (".git", ".lake", ".cache", ".aws", ".codex", "output") or part.startswith(".env")
                               for part in Path(item.name).parts) else item)
        self.run(["tar", "--no-same-owner", "-xf", "-", "-C", destination], input=archive.read_bytes())
        archive.unlink()

    def export(self, source: str, destination: Path) -> None:
        destination.mkdir(parents=True, exist_ok=False)
        archive = self.host / (self.role + "-export.tar")
        archive.write_bytes(self.run(["tar", "-cf", "-", "-C", source, "."]))
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
        archive.unlink()

    def close(self) -> None:
        if not self.native and self.owned and not self.options.keep_containers:
            command([self.options.engine, "stop", self.container], timeout=60,
                    log=self.host / (self.role + "-stop.log"))


class LunClient:
    """Keep one real Lun JSON-lines process; the caller saves each returned state."""

    def __init__(self, runner: Runner, binary: str, environment: dict[str, str], label: str) -> None:
        args, env = runner.argv([binary, "cli"], environment)
        self.log = (runner.host / label).open("wb")
        self.process = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1)
        self.expected_exit = 0

    def request(self, path: str, body: dict) -> dict:
        assert self.process.stdin is not None and self.process.stdout is not None
        self.process.stdin.write(json.dumps({"method": "POST", "path": path, "body": body}) + "\n")
        self.process.stdin.flush()
        # The parent transport/server own call/build deadlines. The controller
        # also bounds an absent protocol response, including failed startup.
        import selectors
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(600):
                raise DemoError("Lun did not reply within 600 seconds; inspect its log")
        text = self.process.stdout.readline()
        if not text:
            raise DemoError("Lun exited before replying; inspect its stderr log")
        response = json.loads(text)
        if response["status"] >= 400:
            self.expected_exit = 1
        return response

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            result = self.process.wait(timeout=15)
            if result != self.expected_exit:
                raise DemoError(f"Lun exited with status {result}; inspect its log")
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise DemoError("Lun did not stop after stdin closed")
        finally:
            self.log.close()


def seed(writer: Runner, linen: dict) -> tuple[str, dict[str, bytes]]:
    """Seed a Git-pinned project; the AI may change only its implementation module."""
    project = writer.root + "/seed"
    pinned_linen = {**linen, "inputRev": linen["rev"]}
    manifest = {"version": "1.3.0", "packagesDir": ".lake/packages", "packages": [pinned_linen],
                "name": "invoice_demo", "lakeDir": ".lake", "fixedToolchain": False}
    files = {"Demo/Cells.lean": STUB.encode(), "lean-toolchain": (ROOT / "lean-toolchain").read_bytes(),
             "lake-manifest.json": json.dumps(manifest, indent=2).encode(),
             ".gitignore": b".lake/\n",
             "lakefile.toml": (f'name = "invoice_demo"\ndefaultTargets = ["Demo"]\n\n'
                               f'[[require]]\nname = "linen"\ngit = {json.dumps(linen["url"])}\nrev = "{linen["rev"]}"\n\n'
                               '[[lean_lib]]\nname = "Demo"\n').encode(),
             "lun.json": json.dumps({key: value for key, value in build_spec("", "").items() if key != "source"}, indent=2).encode()}
    # The protected root checks exact universal theorem types, so live mode
    # cannot satisfy the task with theorem names that prove something weaker.
    files["Demo.lean"] = b'''import Demo.Cells

example (price quantity : Nat) :
    (Demo.subtotal price quantity).run = price * quantity := Demo.subtotal_correct price quantity
example (amount : Nat) : (Demo.tax amount).run = amount / 10 := Demo.tax_correct amount
example (amount levy : Nat) :
    (Demo.total amount levy).run = amount + levy := Demo.total_correct amount levy
'''
    for name, data in files.items():
        writer.write(project + "/" + name, data)
    for args in (["init", "-q", "-b", "main"], ["add", "."],
                 ["-c", "user.name=Demo", "-c", "user.email=demo@lode.example", "-c", "commit.gpgsign=false",
                  "commit", "-qm", "Seed typed invoice cell stubs"]):
        writer.run(["git", "-C", project, *args])
    writer.run(["git", "clone", "-q", "--bare", project, writer.root + "/project.git"])
    return writer.run(["git", "-C", project, "rev-parse", "HEAD"]).decode().strip(), files


def image_context(source: Path, destination: Path, library: str) -> None:
    """Send only compiler source, never the working tree's keys, caches or outputs."""
    destination.mkdir()
    for name in ("Dockerfile", "lean-toolchain", "lakefile.lean", "lake-manifest.json", "Main.lean", library + ".lean"):
        shutil.copyfile(source / name, destination / name)
    shutil.copytree(source / library, destination / library)
    if library == "Lun":
        shutil.copytree(source / "template", destination / "template")


def execute(options: argparse.Namespace, console: Console) -> Path:
    """Create actual cell source/packages and verify a fixed sequence of DAG calls."""
    if options.output == "/tmp/lode-dag.XXXXXX":
        host = Path(tempfile.mkdtemp(prefix="lode-dag.", dir="/tmp"))
    else:
        host = Path(options.output).resolve()
        host.mkdir(mode=0o700, parents=False, exist_ok=False)
    os.chmod(host, 0o700)
    (host / "metadata.json").write_text(json.dumps({"engine": options.engine, "mode": options.mode,
        "lun_commit": command(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).decode().strip(),
        "note": "Working tree changes are included when --build is selected; no provider keys are recorded."}, indent=2))
    console.line(f"Artifacts and logs: {host}")
    runners: list[Runner] = []
    client: LunClient | None = None
    compiler: Runner | None = None
    try:
        console.step(1, "Prepare compilers and isolated scratch environments", options.interactive)
        linen = next(p for p in json.loads((ROOT / "lake-manifest.json").read_text())["packages"] if p["name"] == "linen")
        if options.engine != "native":
            command([options.engine, "info"], log=host / "engine.log", timeout=30)
            # Public builds/local-only runs must not invoke unrelated workstation
            # registry helpers, even on engines that consult them with pull=never.
            auth = host / "public-registry-auth"
            auth.mkdir()
            (auth / "config.json").write_text('{"auths":{}}')
            if options.build:
                for source, library, image, target in ((Path(options.lode_source), "Lode", options.lode_image, None),
                                                        (ROOT, "Lun", options.lun_image, "cell-demo")):
                    if library == "Lode" and options.lode_container:
                        continue
                    context = host / ("image-" + library.lower())
                    image_context(source.resolve(), context, library)
                    args = (["podman", "build", "--authfile", str(auth / "config.json")]
                            if options.engine == "podman" else ["docker", "build"])
                    args += ["-t", image]
                    if target:
                        args += ["--target", target]
                    args += [str(context)]
                    command(args, log=host / (library.lower() + "-image.log"), timeout=3600)
            for image in ([options.lun_image] if options.lode_container else [options.lode_image, options.lun_image]):
                command([options.engine, "image", "inspect", "--format", "{{.Id}}", image],
                        log=host / "image-inspect.log", timeout=30)
            base = "/tmp/" + host.name
            writer = Runner("writer", base + "/writer", options, host, options.lode_image, options.lode_container)
            runners.append(writer)
            compiler = Runner("compiler", base + "/compiler", options, host, options.lun_image)
            runners.append(compiler)
            lode_binary, lun_binary = "lode", "lun"
            writer_cache, compiler_cache = "/opt/lode/cache", "/opt/lun/cache"
            sdk = "/opt/lun/sdk/liaison"
            compiler.run(["test", "-f", sdk + "/Liaison/Wire.lean"])
        else:
            writer = Runner("writer", str(host / "writer"), options, host)
            runners.append(writer)
            compiler = Runner("compiler", str(host / "compiler"), options, host)
            runners.append(compiler)
            lode_binary = str(Path(options.lode_source).resolve() / ".lake/build/bin/lode")
            lun_binary = str(ROOT / ".lake/build/bin/lun")
            cache = host / "cache" / "linen" / linen["rev"]
            cache.parent.mkdir(parents=True)
            console.line("  Copying the existing Linen build into a private cache…", "33")
            shutil.copytree(ROOT / ".lake/packages/linen", cache, symlinks=True)
            writer_cache = compiler_cache = str(host / "cache")
            sdk = str(ROOT / ".lake/packages/liaison")
        if "LUN_CELL_SIGNING_KEY" not in compiler.run([lun_binary, "--help"]).decode():
            raise DemoError("The Lun executable/image predates native cells; use --build from this checkout")
        console.passed("Lode and Lun are available; compiler network is disabled for image runs")

        console.step(2, "Seed the /tmp Git repository and pinned DAG contract", options.interactive)
        initial, files = seed(writer, linen)
        repository = "file://" + writer.root + "/project.git"
        request = session_request(repository, options.mode == "scripted")
        writer.write(writer.root + "/session.json", json.dumps(request).encode())
        console.passed(f"{repository} at {initial[:12]}; only Demo/Cells.lean may change")

        console.step(3, "Lode authors, checks and publishes the cells — " + options.mode.upper(), options.interactive)
        env = {"LODE_WORKDIR": writer.root + "/lode", "LODE_PACKAGE_CACHE": writer_cache,
               "LODE_MAX_STEPS": str(options.max_steps), "LODE_MODEL_MAX_TOKENS": str(options.max_tokens),
               "LODE_MODEL_TIMEOUT": str(options.model_timeout), "LODE_CHECK_TIMEOUT": str(options.build_timeout)}
        if options.mode == "live":
            for key, name in MODEL_ENV.items():
                if getattr(options, key):
                    env[name] = getattr(options, key)
            if options.key_env in os.environ:
                env["LODE_MODEL_API_KEY"] = os.environ[options.key_env]
        else:
            for name in (*MODEL_ENV.values(), "LODE_MODEL_API_KEY", "LODE_SETTINGS", "LODE_SECRETS_URL",
                         "LODE_SECRETS_MODEL_KEY_PATH", "LODE_SECRETS_TOKEN"):
                env[name] = ""
        invocation = [lode_binary, "run", "--config", writer.root + "/session.json"]
        if not writer.native:
            # Keep a deadline inside a reused container even if the client dies.
            invocation = ["timeout", "--signal=TERM", "--kill-after=5s", str(options.run_timeout), *invocation]
        argv, process_env = writer.argv(invocation, env)
        timed_out = False
        try:
            result = subprocess.run(argv, check=False, env=process_env, input=TASK.encode(), capture_output=True,
                                    timeout=options.run_timeout + 10)
            answer, progress, returncode = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            answer, progress, returncode = error.stdout or b"", error.stderr or b"", 124
            timed_out = True
        secret = env.get("LODE_MODEL_API_KEY", "").encode()
        scrub = lambda value: value.replace(secret, b"[redacted]") if secret else value
        (host / "lode-answer.log").write_bytes(scrub(answer))
        (host / "lode-progress.log").write_bytes(scrub(progress))
        if returncode:
            reason = "timed out" if timed_out or returncode == 124 else "did not finish"
            raise DemoError(f"Lode {reason}; see lode-progress.log. No scripted fallback was used.")
        match = re.search(rb"^\[lode\] session ([A-Za-z0-9_-]+)", progress, re.MULTILINE)
        if not match:
            raise DemoError("Lode did not report its session ID; inspect lode-progress.log")
        session = match.group(1).decode()
        console.passed(f"Session {session}; {'actual configured AI' if options.mode == 'live' else 'scripted model, real tools/build/Git'}")

        console.step(4, "Verify the published revision and transfer its local repository", options.interactive)
        receipt = json.loads(writer.run([lode_binary, "output", session, "--format", "git"], env=env))
        commit = receipt["commit"]
        if commit == initial or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
            raise DemoError("Lode did not publish a new source revision")
        bare = writer.root + "/project.git"
        actual = writer.run(["git", "--git-dir=" + bare, "rev-parse", "main"]).decode().strip()
        if actual != commit:
            raise DemoError("Published receipt does not match the local repository")
        for name, data in files.items():
            if name != "Demo/Cells.lean" and writer.run(["git", "--git-dir=" + bare, "show", commit + ":" + name]) != data:
                raise DemoError(f"Lode changed protected scaffold {name}; inspect its published source")
        changed = writer.run(["git", "--git-dir=" + bare, "diff", "--name-only", initial, commit]).decode().splitlines()
        if changed != ["Demo/Cells.lean"]:
            raise DemoError("Lode changed files outside the implementation module")
        (host / "lode-receipt.json").write_text(json.dumps(receipt, indent=2))
        writer.export(bare, host / "project.git")
        compiler.upload(host / "project.git", compiler.root + "/project.git")
        console.passed(f"Immutable revision {commit}; no remote publication")

        console.step(5, "Compile and sign three native cells under /tmp", options.interactive)
        home = compiler.root + "/keys"
        compiler.run(["mkdir", "-m", "700", home])
        gpg = ["gpg", "--no-options", "--homedir", home, "--batch"]
        compiler.run([*gpg, "--passphrase", "", "--quick-generate-key", "Demo compiler <compiler@lode-dag.example>",
                      "ed25519", "sign", "1d"], log="key-generation.log", timeout=30)
        listing = compiler.run([*gpg, "--with-colons", "--list-secret-keys"]).decode()
        fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        keyring = compiler.root + "/compiler.gpg"
        compiler.write(keyring, compiler.run([*gpg, "--export", fingerprint]))
        environment = {"LUN_WORKDIR": compiler.root + "/lun", "LUN_ID_SALT": "local-cell-guide",
                       "LUN_CELL_SIGNING_KEY": fingerprint, "LUN_CELL_SIGNING_HOME": home, "LUN_CELL_KEYRING": keyring,
                       "LUN_PACKAGE_CACHE": compiler_cache, "LUN_LIAISON_SDK_PATH": sdk,
                       "LUN_BUILD_TIMEOUT": str(options.build_timeout), "LUN_CALL_TIMEOUT": str(options.call_timeout)}
        client = LunClient(compiler, lun_binary, environment, "lun.log")
        spec = build_spec("file://" + compiler.root + "/project.git", commit)
        (host / "build-request.json").write_text(json.dumps(spec, indent=2))
        response = client.request("/v0/builds", spec)
        if response["status"] != 200 or response["body"].get("state") != "ready":
            (host / "build-failure.json").write_text(json.dumps(response, indent=2))
            raise DemoError("Lun refused the source/contract/build; inspect build-failure.json and lun.log")
        build = response["body"]
        if build["runtimeContract"] != "stateless-cells-v5" or len(build["cells"]) != 3:
            raise DemoError("The build did not attest the native-cell runtime and all three cells")
        pins = {cell["name"]: cell["pin"] for cell in build["cells"]}
        for node in build["graphs"][0]["nodes"]:
            if "function" in node and node.get("cell") != pins[node["function"]]:
                raise DemoError("A DAG computation is missing its exact cell pin")
        (host / "build.json").write_text(json.dumps(build, indent=2))
        console.passed("Three signed local cell packages, exact pins on every computation")
        for name, pin in pins.items():
            console.line(f"  {name:10} {pin[:16]}…", "33")

        console.step(6, "Run the DAG one caller-owned step at a time", options.interactive)
        state = None
        path = f'/v0/builds/{build["id"]}/graphs/invoice'
        authority = {"policy": {"effects": [], "domains": []},
                     "binding": {"org_id": "demo", "user_id": "local", "graph_id": "invoice"}}

        def step(number: int, now: int, inputs: dict, expected: tuple[int, int, int], unchanged: bool = False) -> dict:
            nonlocal state
            body = {**authority, "inputs": inputs, "now": now, "state": state}
            assert client is not None
            reply = client.request(path, body)
            if reply["status"] != 200:
                raise DemoError(f"DAG step {number} failed: {reply}")
            result = reply["body"]
            values = {node["function"]: node.get("output") for node in result["nodes"] if "function" in node}
            if tuple(values.get(name) for name in ("subtotal", "tax", "total")) != expected or result["nextCallAt"] is not None:
                raise DemoError(f"Wrong DAG step {number}: {result}")
            if unchanged and result["changed"]:
                raise DemoError("An unchanged input unexpectedly executed the DAG")
            state = result["state"]
            (host / f"step-{number}.json").write_text(json.dumps(result, indent=2))
            (host / "state.json").write_text(json.dumps(state, indent=2))
            changed = [node.get("function", node.get("input")) for node in result["changed"]]
            console.passed(f"step {number}: {inputs} → subtotal={values['subtotal']}, tax={values['tax']}, total={values['total']}; changed={changed}")
            return result

        step(1, 1000, {"price": 100, "quantity": 2}, (200, 20, 220))
        step(2, 2000, {"quantity": 3}, (300, 30, 330))
        step(3, 2500, {"quantity": 3}, (300, 30, 330), unchanged=True)
        step(4, 3000, {"price": 200}, (600, 60, 660))
        saved = (host / "state.json").read_bytes()
        rejected = client.request(path, {**authority, "state": state, "now": 4000, "inputs": {"quantity": "wrong"}})
        if rejected["status"] != 400 or "state" in rejected["body"] or (host / "state.json").read_bytes() != saved:
            raise DemoError("Invalid input was not refused while retaining caller state")
        (host / "refused-input.json").write_text(json.dumps(rejected, indent=2))
        console.passed("wrong-type input refused; caller's last good state retained")

        console.step(7, "Restart Lun and resume the saved JSON state", options.interactive)
        client.close()
        client = LunClient(compiler, lun_binary, environment, "lun-restart.log")
        state = json.loads((host / "state.json").read_text())
        step(5, 5000, {"quantity": 4}, (800, 80, 880))
        client.close()
        client = None
        console.passed("Ready code, signed packages and caller-owned state survive a process restart")

        console.step(8, "Export source, signed local cells and public verification material", options.interactive)
        compiler.export(compiler.root + f'/lun/builds/{build["id"]}/cells', host / "cells")
        (host / "compiler.gpg").write_bytes(compiler.read(keyring))
        sizes = {}
        for name, pin in pins.items():
            package = host / "cells" / name
            record = (package / "manifest.json").read_bytes()
            manifest = json.loads(record)
            if hashlib.sha256(record).hexdigest() != pin or manifest["version"] != 2:
                raise DemoError("Export changed a signed cell manifest")
            payload = (package / "worker").read_bytes()
            if not 0 < len(payload) <= 128 * 1024 * 1024:
                raise DemoError("Exported cell exceeds Linen's 128 MiB artifact bound")
            if hashlib.sha256(payload).hexdigest() != manifest["artifactSha256"] or len(payload) != manifest["artifactBytes"]:
                raise DemoError("Export changed a native cell payload")
            sizes[name] = len(payload)
        summary = {"mode": options.mode, "engine": options.engine, "publishedCommit": commit,
                   "buildId": build["id"], "runtimeContract": build["runtimeContract"], "pins": pins, "artifactBytes": sizes,
                   "totals": [220, 330, 330, 660, 880], "invalidInputRefused": True, "restartPassed": True,
                   "containers": [{"role": r.role, "id": r.container, "root": r.root, "owned": r.owned} for r in runners if not r.native]}
        (host / "result.json").write_text(json.dumps(summary, indent=2))
        console.passed("Exported exact signed packages and public keyring; no model or signing private keys")
        return host
    finally:
        already_failed = sys.exc_info()[0] is not None
        if client is not None:
            try:
                client.close()
            except (DemoError, OSError, subprocess.TimeoutExpired):
                pass
        if compiler is not None and (compiler.native or not options.keep_containers):
            try:
                compiler.run(["gpgconf", "--homedir", compiler.root + "/keys", "--kill", "gpg-agent"], timeout=10)
            except (DemoError, OSError, subprocess.TimeoutExpired):
                pass
            if compiler.native:
                shutil.rmtree(Path(compiler.root) / "keys", ignore_errors=True)
        cleanup_errors = []
        for runner in reversed(runners):
            try:
                runner.close()
            except (DemoError, OSError, subprocess.TimeoutExpired) as error:
                cleanup_errors.append(str(error))
                console.line(f"Cleanup: {error}", "31")
        if cleanup_errors and not already_failed:
            raise DemoError("Could not stop all owned containers; inspect the cleanup messages")


def main(argv: list[str] | None = None) -> int:
    """Validate configuration and approve a concrete plan before making changes."""
    console = Console()
    try:
        options = configuration(sys.argv[1:] if argv is None else argv)
        options.lode_source = str((ROOT / options.lode_source).resolve())
        console.line("Lode → local Git → signed cells → invoice DAG")
        for field in ("engine", "mode", "lode_image", "lun_image", "lode_container", "build", "output", "max_steps", "model"):
            console.line(f"  {field}: {getattr(options, field)!r} [{options.sources[field]}]", "33")
        if options.dry_run:
            return 0
        prompt_model(options, console)
        if options.mode == "live":
            console.line(f"  AI: {options.provider or 'container default'}/{options.model or 'container default'}; "
                         f"at most {options.max_steps} model steps", "33")
        if (options.mode == "live" and not options.lode_container and
                (not options.model or not options.provider or not os.environ.get(options.key_env))):
            raise DemoError("Live authoring needs --provider/--model (or LODE_MODEL_PROVIDER/LODE_MODEL_NAME) and the key in "
                                f"{options.key_env}. Configure credentials outside chat; or choose --mode scripted explicitly.")
        if not options.yes:
            if not sys.stdin.isatty():
                raise DemoError("Pass --yes to approve the displayed plan non-interactively (or --dry-run to preview)")
            text = "Create this isolated /tmp demo" + (" and make real AI calls" if options.mode == "live" else " using scripted responses")
            if input(text + "? [y/N] ").lower() != "y":
                raise DemoError("Demo declined")
        host = execute(options, console)
        console.passed("All DAG steps verified" + (" — SCRIPTED REHEARSAL" if options.mode == "scripted" else " — LIVE AI AUTHORING"))
        print(host)
        return 0
    except (DemoError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        console.line("Error: " + str(error), "31")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
