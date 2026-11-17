#!/usr/bin/env python3
"""Offline regression tests for secret-manager native cache provisioning.

Run with: python3 -m unittest discover -s hack -p test_secret_manager.py
"""
from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SOURCE = Path(__file__).with_name("secret-manager.sh").read_text(encoding="utf-8")
# Load only provisioning functions, never the wrapper's credential/CLI dispatch.
FUNCTIONS = SOURCE[SOURCE.index("native_cli_ready() {"):SOURCE.index("run_native() {")]
MOCKS = r'''
curl() { printf downloaded > "$NATIVE_ROOT/downloaded"; }
tar() {
    mkdir -p "$NATIVE_STAGE/src/cmd/secret-manager"
    touch "$NATIVE_STAGE/src/cmd/secret-manager/"{main.py,requirements.txt}
}
uv() {
    if [ "$1" = venv ]; then
        mkdir -p "$NATIVE_STAGE/venv/bin"
        printf '#!/bin/sh\nexit 0\n' > "$NATIVE_STAGE/venv/bin/python3"
        chmod +x "$NATIVE_STAGE/venv/bin/python3"
    fi
}
'''


class NativeCacheTests(unittest.TestCase):
    def setUp(self):
        contexts = ExitStack()
        self.addCleanup(contexts.close)
        self.root = Path(contexts.enter_context(tempfile.TemporaryDirectory()))
        self.commit = "b" * 40
        self.cache = self.root / self.commit
        self.lock = self.root / ".lock"

    def provision(self, setup=""):
        script = r'''
set -euo pipefail
NATIVE_ROOT="$1"
NATIVE_COMMIT="$2"
NATIVE_DIR="$NATIVE_ROOT/$NATIVE_COMMIT"
NATIVE_PYTHON="$NATIVE_DIR/venv/bin/python3"
NATIVE_LOCK="$NATIVE_ROOT/.lock"
NATIVE_STAGE=""
''' + FUNCTIONS + MOCKS + setup + "\nensure_native_cli\n"
        return subprocess.run(
            ["bash", "-c", script, "test", str(self.root), self.commit],
            text=True, capture_output=True, timeout=10, check=False,
        )

    def test_provision_preserves_old_cache_and_releases_lock(self):
        old = self.root / ("a" * 40)
        old.mkdir()
        (old / "in-use").touch()
        os.utime(old, (time.time() - 10 * 86400,) * 2)
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((old / "in-use").exists(), "deleted another pin's cache")
        self.assertTrue(os.access(self.cache / "venv/bin/python3", os.X_OK))
        self.assertFalse(self.lock.exists())
        self.assertFalse(list(self.root.glob(".stage.*")))

    def test_dead_lock_is_preserved_for_manual_recovery(self):
        self.lock.mkdir()
        (self.lock / "pid").write_text("123456")
        result = self.provision("\nkill() { return 1; }\n")
        self.assertNotEqual(result.returncode, 0, "silently reclaimed stale lock")
        self.assertIn("abandoned", result.stderr)
        self.assertEqual((self.lock / "pid").read_text(), "123456")
        self.assertFalse((self.root / "downloaded").exists())

    def test_abandoned_pidless_lock_is_preserved(self):
        self.lock.mkdir()
        result = self.provision('\nfind() { printf "%s\\n" "$NATIVE_LOCK"; }\n')
        self.assertNotEqual(result.returncode, 0, "silently reclaimed pidless lock")
        self.assertIn("abandoned", result.stderr)
        self.assertTrue(self.lock.exists())
        self.assertFalse((self.root / "downloaded").exists())

    def test_invalid_cache_fails_before_downloading(self):
        self.cache.mkdir()
        (self.cache / "keep").touch()
        result = self.provision()
        self.assertNotEqual(result.returncode, 0, "published inside invalid cache")
        self.assertIn("incomplete", result.stderr)
        self.assertEqual([p.name for p in self.cache.iterdir()], ["keep"])
        self.assertFalse((self.root / "downloaded").exists())
        self.assertFalse(self.lock.exists())

    def test_live_lock_waits_for_published_cache_without_removing_lock(self):
        self.lock.mkdir()
        (self.lock / "pid").write_text(str(os.getpid()))
        result = self.provision(r'''
sleep() {
    mkdir -p "$NATIVE_DIR/venv/bin"
    touch "$NATIVE_PYTHON"
    chmod +x "$NATIVE_PYTHON"
}
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.lock / "pid").read_text(), str(os.getpid()))
        self.assertFalse((self.root / "downloaded").exists())

    def test_failed_download_removes_owned_lock_and_stage(self):
        result = self.provision("\ncurl() { return 1; }\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not download", result.stderr)
        self.assertFalse(self.lock.exists())
        self.assertFalse(list(self.root.glob(".stage.*")))
        self.assertFalse(self.cache.exists())

    def test_publication_checks_readiness_even_if_mv_succeeds(self):
        result = self.provision("\nmv() { return 0; }\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not publish", result.stderr)
        self.assertFalse(self.lock.exists())
        self.assertFalse(list(self.root.glob(".stage.*")))

    def test_ready_cache_does_not_require_lock_or_download(self):
        python = self.cache / "venv/bin/python3"
        python.parent.mkdir(parents=True)
        python.write_text("#!/bin/sh\nexit 0\n")
        python.chmod(0o755)
        self.lock.mkdir()
        result = self.provision()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.lock.exists())
        self.assertFalse((self.root / "downloaded").exists())


if __name__ == "__main__":
    unittest.main()
