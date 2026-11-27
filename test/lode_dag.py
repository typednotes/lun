"""Fast offline regressions for Examples/lode-dag/SPEC.md; Python 3.12+."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("lode_dag_demo", ROOT / "Examples/lode-dag/_demo.py")
assert SPEC and SPEC.loader
demo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(demo)


class DemoTests(unittest.TestCase):
    """Exercise client boundaries without an engine, model or Lean build."""

    def test_s1_native_cannot_accidentally_run_live_ai(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(demo.DemoError):
            demo.configuration(["--engine", "native"])

    def test_s1_scripted_is_explicit_and_uses_real_tool_calls(self):
        self.assertNotIn("model", demo.session_request("file:///tmp/project.git", False))
        request = demo.session_request("file:///tmp/project.git", True)
        self.assertEqual(request["model"]["api"], "scripted")
        self.assertEqual([item["calls"][0]["name"] for item in request["model"]["script"][:-1]],
                         ["read", "edit", "check", "publish"])

    def test_s2_seed_locks_dependency_without_network_update(self):
        class Writer:
            root = "/tmp/test-writer"
            def write(self, path, data):
                pass
            def run(self, args):
                return b"a" * 40
        _, files = demo.seed(Writer(), {"name": "linen", "url": "https://example.org/linen", "rev": "b" * 40,
                                      "inputRev": "v4.1.0"})
        manifest = json.loads(files["lake-manifest.json"])
        self.assertEqual(manifest["packages"][0]["inputRev"], "b" * 40)
        self.assertIn(b"b" * 40, files["lakefile.toml"])

    def test_s5_precedence_and_dry_run_do_not_invoke_engine(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {}, clear=True):
            defaults = Path(temp) / "defaults.toml"
            defaults.write_text('[demo]\nengine="docker"\nmax_steps=12\n')
            with patch.dict(os.environ, {"LODE_DAG_ENGINE": "podman"}):
                args = demo.configuration(["--defaults", str(defaults), "--engine", "native", "--mode", "scripted"])
                self.assertEqual(args.engine, "native")
                self.assertEqual(args.max_steps, 12)
                output = Path(temp) / "never-created"
                with patch.object(demo, "command", side_effect=AssertionError("engine called")), \
                     contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(demo.main(["--dry-run", "--output", str(output)]), 0)
                self.assertFalse(output.exists())

    def test_s5_invalid_configuration_fails_before_work(self):
        with patch.dict(os.environ, {}, clear=True):
            for args in (["--max-steps", "0"], ["--key-env", "secret=value"], ["--auth-url", "file:///etc/passwd"]):
                with self.subTest(args=args), self.assertRaises(demo.DemoError):
                    demo.configuration(args)

    def test_s6_scripted_never_prompts_for_credentials(self):
        with patch.object(demo.getpass, "getpass", side_effect=AssertionError("secret prompt")), \
             patch.object(demo.webbrowser, "open", side_effect=AssertionError("browser opened")):
            demo.prompt_model(argparse.Namespace(mode="scripted"), demo.Console())

    def test_s6_browser_prompt_keeps_key_in_environment_only(self):
        args = argparse.Namespace(mode="live", lode_container="", provider="", model="", api="",
                                  auth_url="https://example.org/keys", key_env="DEMO_KEY")
        with patch.dict(os.environ, {}, clear=True), patch.object(demo.sys.stdin, "isatty", return_value=True), \
             patch("builtins.input", side_effect=["openai", "account-model", "responses"]), \
             patch.object(demo.getpass, "getpass", return_value="fixture-key"), \
             patch.object(demo.webbrowser, "open", return_value=True) as browser, \
             contextlib.redirect_stderr(io.StringIO()):
            demo.prompt_model(args, demo.Console())
            browser.assert_called_once_with("https://example.org/keys", new=2)
            self.assertEqual(os.environ["DEMO_KEY"], "fixture-key")
            self.assertNotIn("fixture-key", repr(args))
            self.assertNotIn("DEMO_KEY", demo.public_environment())

    def test_s6_export_refuses_archive_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w") as bundle:
                item = tarfile.TarInfo("../escaped")
                item.size = 1
                bundle.addfile(item, io.BytesIO(b"x"))
            runner = object.__new__(demo.Runner)
            runner.role, runner.host = "writer", Path(temp)
            runner.run = lambda *args, **kwargs: archive.getvalue()
            with self.assertRaises(tarfile.FilterError):
                runner.export("/tmp/export", Path(temp) / "destination")
            self.assertFalse((Path(temp) / "escaped").exists())

    def test_s6_existing_container_is_not_stopped(self):
        runner = object.__new__(demo.Runner)
        runner.native, runner.owned = False, False
        runner.options = argparse.Namespace(keep_containers=False)
        with patch.object(demo, "command", side_effect=AssertionError("stopped user's container")):
            runner.close()

    def test_s6_local_startup_never_uses_workstation_registry_auth(self):
        options = argparse.Namespace(engine="podman", keep_containers=False)
        with tempfile.TemporaryDirectory() as temp, patch.object(demo, "command", return_value=b"fixture-id") as run:
            demo.Runner("compiler", "/tmp/demo/compiler", options, Path(temp), "localhost/lun:cells-demo")
            argv = run.call_args_list[0].args[0]
            self.assertEqual(argv[:3], ["podman", "run", "--authfile"])
            self.assertIn("--pull=never", argv)
            self.assertIn("--network=none", argv)
            self.assertEqual(argv[3], str(Path(temp) / "public-registry-auth/config.json"))

    def test_s7_native_output_refuses_existing_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict(os.environ, {}, clear=True):
                args = demo.configuration(["--engine", "native", "--mode", "scripted", "--output", temp])
            with self.assertRaises(FileExistsError):
                demo.execute(args, demo.Console())


if __name__ == "__main__":
    unittest.main()
