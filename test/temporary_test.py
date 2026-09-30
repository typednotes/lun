"""Exercise the actual syscall adapter; no provider credentials are needed."""
import importlib.util
from pathlib import Path
import tempfile
import sys
sys.dont_write_bytecode = True
import os
import unittest

spec = importlib.util.spec_from_file_location("temporary", Path(__file__).resolve().parents[1] / "template/LunDriver/temporary.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
execute = module.execute
base = sys.argv.pop() if len(sys.argv) > 1 else None


class TemporaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "bound"
        self.outside = self.base / "outside"
        self.outside.mkdir()

    def call(self, operation, parts=None, user="user-1", contents="inside"):
        return execute({"root": str(self.root), "org": "org-1", "user": user,
                        "operation": operation, "parts": parts or ["note"],
                        "contents": contents.encode().hex()})

    def test_roundtrip_and_user_boundary(self):
        self.call("write")
        self.assertEqual(self.call("read"), b"inside".hex())
        with self.assertRaises(FileNotFoundError):
            self.call("read", user="user-2")
        self.assertFalse((self.root / "org-1/user-2").exists())
        self.call("delete")
        with self.assertRaises(FileNotFoundError):
            self.call("read")

    def test_read_never_creates_directories(self):
        with self.assertRaises(FileNotFoundError):
            self.call("read", ["missing", "note"])
        self.assertFalse(self.root.exists())

    def test_traversal_and_root_symlink(self):
        for parts in (["..", "escape"], ["."], ["a/b"], ["a\\b"], ["\0"]):
            with self.assertRaises(ValueError):
                self.call("write", parts)
        self.root.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.call("write")
        self.assertEqual(list(self.outside.iterdir()), [])

    def test_ancestor_symlink_and_final_symlink(self):
        self.call("write")
        user = self.root / "org-1/user-1"
        (user / "escape").symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.call("write", ["escape", "note"])
        external = self.outside / "secret"
        external.write_text("outside")
        (user / "link").symlink_to(external)
        with self.assertRaises(OSError):
            self.call("read", ["link"])
        self.call("write", ["link"])
        self.assertEqual(external.read_text(), "outside")
        self.assertFalse((user / "link").is_symlink())

    def test_hardlink_does_not_read_or_overwrite_outside(self):
        self.call("write")
        external = self.outside / "secret"
        external.write_text("outside")
        os.link(external, self.root / "org-1/user-1/hard")
        with self.assertRaises(PermissionError):
            self.call("read", ["hard"])
        self.call("write", ["hard"])
        self.assertEqual(external.read_text(), "outside")
        self.assertEqual(self.call("read", ["hard"]), b"inside".hex())


unittest.main()
