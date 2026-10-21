#!/usr/bin/env python3
"""Offline tests for a clean source checkout's pinned wheel preparation."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("portable_runtime", ROOT / "Scripts/prepare-portable-runtime.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


class PortableWheelsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.wheelhouse = self.root / "wheels"
        self.lock = self.root / "python-wheels.lock.json"
        self.requirements = self.root / "requirements.txt"
        self.name = "example_package-1.2.3-py3-none-any.whl"
        self.data = b"verified fixture wheel bytes"
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.lock.write_text(json.dumps({self.name: self.digest}) + "\n")
        self.original_lock = self.lock.read_bytes()
        self.requirements.write_text("# Exact source pins\nexample-package==1.2.3\n")

    def prepare(self):
        return runtime.prepare_wheels(Path("/unused/python"), self.wheelhouse, self.lock, self.requirements)

    def downloader(self, data):
        def download(*arguments):
            self.assertIn("--require-hashes", arguments)
            self.assertIn("--no-deps", arguments)
            pins = Path(arguments[arguments.index("--requirement") + 1]).read_text()
            self.assertEqual(pins, "example_package==1.2.3 --hash=sha256:" + self.digest + "\n")
            destination = Path(arguments[arguments.index("--dest") + 1])
            (destination / self.name).write_bytes(data)
        return download

    def test_clean_checkout_downloads_missing_locked_wheel_without_rewriting_lock(self):
        with patch.object(runtime, "run", side_effect=self.downloader(self.data)) as download:
            self.assertEqual(self.prepare(), [self.wheelhouse / self.name])
            download.assert_called_once()
        self.assertEqual((self.wheelhouse / self.name).read_bytes(), self.data)
        self.assertEqual(self.lock.read_bytes(), self.original_lock)

    def test_valid_cache_is_used_without_network_and_unlocked_wheels_are_not_selected(self):
        self.wheelhouse.mkdir()
        (self.wheelhouse / self.name).write_bytes(self.data)
        (self.wheelhouse / "unreviewed-9.9-py3-none-any.whl").write_bytes(b"not selected")
        with patch.object(runtime, "run") as download:
            self.assertEqual(self.prepare(), [self.wheelhouse / self.name])
            download.assert_not_called()
        self.assertEqual(self.lock.read_bytes(), self.original_lock)

    def test_changed_cache_fails_before_download_without_overwriting_it(self):
        self.wheelhouse.mkdir()
        cached = self.wheelhouse / self.name
        cached.write_bytes(b"changed")
        with patch.object(runtime, "run") as download, self.assertRaises(SystemExit):
            self.prepare()
        download.assert_not_called()
        self.assertEqual(cached.read_bytes(), b"changed")
        self.assertEqual(self.lock.read_bytes(), self.original_lock)

    def test_download_hash_mismatch_never_enters_cache_or_changes_lock(self):
        with patch.object(runtime, "run", side_effect=self.downloader(b"wrong download")), self.assertRaises(SystemExit):
            self.prepare()
        self.assertEqual(list(self.wheelhouse.iterdir()), [])
        self.assertEqual(self.lock.read_bytes(), self.original_lock)

    def test_requirements_must_match_lock_before_any_download(self):
        self.requirements.write_text("example-package==2.0\n")
        with patch.object(runtime, "run") as download, self.assertRaises(SystemExit):
            self.prepare()
        download.assert_not_called()
        self.assertEqual(self.lock.read_bytes(), self.original_lock)

    def test_missing_lock_is_not_silently_regenerated(self):
        self.lock.unlink()
        with patch.object(runtime, "run") as download, self.assertRaises(SystemExit):
            self.prepare()
        download.assert_not_called()
        self.assertFalse(self.lock.exists())


if __name__ == "__main__":
    unittest.main()
