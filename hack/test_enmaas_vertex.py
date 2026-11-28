#!/usr/bin/env python3

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

from test_enmaas_shell import write_stub


ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "ci-operator/step-registry/enmaas/deploy/enmaas-deploy-commands.sh"
STUB = r'''
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

args = sys.argv[1:]
failure = os.environ.get("FAIL_STEP", "")
if Path(sys.argv[0]).stem == "openssl":
    directory = Path(args[args.index("-out") + 1]).parent if "-out" in args else Path(args[args.index("-in") + 1]).parent
    operation = "generation" if args[0] == "genpkey" else "validation"
    if failure == operation:
        print("UNSAFE_OUTPUT", file=sys.stderr)
        status = 7
    elif failure == "malformed-key" and operation == "generation":
        (directory / "private.pem").write_text("synthetic invalid key")
        status = 0
    else:
        status = subprocess.run([os.environ["REAL_OPENSSL"], *args], check=False).returncode
    record = {"operation": operation, "directory": str(directory)}
else:
    assert "--loglevel=0" in args and "--request-timeout=30s" in args
    assert args[args.index("-n") + 1] == "enmaas"
    if "create" in args:
        operation = "rendering"
        assert args[args.index("create"):][:4] == ["create", "secret", "generic", "vertex-sa-key"]
        assert "--save-config=false" in args and "--dry-run=client" in args
        document = Path(next(value.split("=", 2)[2] for value in args if value.startswith("--from-file=sa-key.json=")))
        directory = document.parent
        data = json.loads(document.read_text())
        key = data["private_key"]
        assert data["type"] == "service_account" and data["client_email"].endswith(".invalid")
        assert data["project_id"] == "enmaas-ci-unregistered-test" and "\n" in key
        assert key == (directory / "private.pem").read_text()
        assert all(key not in argument for argument in sys.argv)
        assert directory.stat().st_mode & 0o777 == 0o700
        assert all(path.stat().st_mode & 0o777 == 0o600 for path in directory.iterdir())
        checked = subprocess.run([os.environ["REAL_OPENSSL"], "rsa", "-check", "-noout"],
                                 input=key.encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        assert checked.returncode == 0
        result = subprocess.run([os.environ["REAL_OC"], "--kubeconfig=/dev/null", "--server=http://127.0.0.1:1", *args],
                                capture_output=True, check=False)
        assert result.returncode == 0
        rendered = json.loads(result.stdout)
        assert rendered["metadata"]["name"] == "vertex-sa-key" and rendered["metadata"]["namespace"] == "enmaas"
        assert not rendered["metadata"].get("annotations") and set(rendered["data"]) == {"sa-key.json"}
        assert json.loads(base64.b64decode(rendered["data"]["sa-key.json"])) == data
        record = {"operation": operation, "directory": str(directory), "fingerprint": hashlib.sha256(key.encode()).hexdigest()}
        sys.stdout.buffer.write(b"{" if failure == "malformed" else result.stdout)
        if failure == operation or failure == "verbose":
            print("UNSAFE_OUTPUT" + key + json.dumps(data), file=sys.stderr)
    else:
        operation = "submission"
        assert "--server-side" in args and "--field-manager=enmaas-ci-vertex" in args and "--force-conflicts" in args
        manifest = Path(args[args.index("-f") + 1])
        directory = manifest.parent
        rendered = json.loads(manifest.read_text())
        assert manifest.stat().st_mode & 0o777 == 0o600
        record = {"operation": operation, "directory": str(directory)}
        if failure == operation or failure == "verbose":
            print("UNSAFE_OUTPUT" + json.dumps(rendered))
            print("UNSAFE_OUTPUT" + json.dumps(rendered), file=sys.stderr)
    status = 9 if failure == operation else 0
with Path(os.environ["METADATA"]).open("a") as stream:
    stream.write(json.dumps(record) + "\n")
if failure == "block" and operation == "submission":
    time.sleep(30)
sys.exit(status)
'''


class EnmaasVertexTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="vertex tests "))
        self.addCleanup(shutil.rmtree, self.directory)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.openssl = shutil.which("openssl")
        self.decoder = shutil.which("oc")
        self.assertTrue(self.openssl is not None and self.decoder is not None, "openssl and oc are required")
        for command in ("oc", "openssl"):
            write_stub(self.bin / command, STUB)
        source = DEPLOY.read_text(encoding="utf-8")
        self.source = "create_vertex_test_secret() (" + source.split("create_vertex_test_secret() (", 1)[1].split(
            "\n)\ncreate_vertex_test_secret", 1)[0] + "\n)\ncreate_vertex_test_secret\necho AFTER_VERTEX_SETUP\n"
        self.metadata = self.directory / "metadata.jsonl"
        self.environment = {"PATH": str(self.bin) + ":/usr/local/bin:/usr/bin:/bin", "HOME": str(self.directory),
                            "SHARED_DIR": str(self.directory / "shared"), "ARTIFACT_DIR": str(self.directory / "artifacts"),
                            "TMPDIR": str(self.directory / "artifacts"), "METADATA": str(self.metadata),
                            "REAL_OPENSSL": str(Path(self.openssl).resolve()), "REAL_OC": str(Path(self.decoder).resolve())}
        (self.directory / "shared").mkdir()
        (self.directory / "artifacts").mkdir()
        self.addCleanup(self.remove_private_directories)

    def records(self):
        return [json.loads(line) for line in self.metadata.read_text().splitlines()] if self.metadata.exists() else []

    def remove_private_directories(self):
        for directory in {Path(record["directory"]) for record in self.records()}:
            if directory.parent == Path("/tmp") and directory.name.startswith("enmaas-vertex-test-"):
                shutil.rmtree(directory, ignore_errors=True)

    def run_setup(self, failure="", source=None):
        self.remove_private_directories()
        self.metadata.unlink(missing_ok=True)
        result = subprocess.run(["bash", "-euxv", "-c", source or self.source], cwd=self.directory,
                                env={**self.environment, "FAIL_STEP": failure}, capture_output=True,
                                text=True, check=False, timeout=30)
        self.assertFalse("UNSAFE_OUTPUT" in result.stdout + result.stderr, "sensitive child output escaped")
        self.assertFalse(any(Path(record["directory"]).exists() for record in self.records()), "private files survived")
        self.assertEqual(list((self.directory / "shared").iterdir()), [])
        self.assertEqual(list((self.directory / "artifacts").iterdir()), [])
        return result

    def test_old_dummy_is_not_a_private_key(self):
        result = subprocess.run([self.openssl, "pkey", "-check", "-noout"], input=b"dummy",
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=15)
        self.assertNotEqual(result.returncode, 0)

    def test_real_key_json_and_actual_secret_render_are_private_and_fresh(self):
        fingerprints = []
        for _ in range(2):
            result = self.run_setup("verbose")
            self.assertEqual(result.returncode, 0, "ephemeral setup failed")
            self.assertTrue("AFTER_VERTEX_SETUP" in result.stdout, "setup did not continue after success")
            records = self.records()
            self.assertEqual([record["operation"] for record in records],
                             ["generation", "validation", "rendering", "submission"])
            fingerprints.append(next(record["fingerprint"] for record in records if "fingerprint" in record))
            self.assertTrue(all(ROOT not in Path(record["directory"]).parents for record in records))
        self.assertTrue(fingerprints[0] != fingerprints[1], "private key was reused")

    def test_failures_are_sanitized_and_cleaned_without_continuing(self):
        for failure in ("generation", "validation", "malformed-key", "rendering", "malformed", "submission"):
            with self.subTest(failure=failure):
                result = self.run_setup(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue("ERROR: Ephemeral Vertex test Secret failed during" in result.stderr,
                                "sanitized failure diagnostic missing")
                self.assertFalse("AFTER_VERTEX_SETUP" in result.stdout, "setup continued after failure")
                if failure != "submission":
                    self.assertFalse(any(record["operation"] == "submission" for record in self.records()))

    def test_serialization_failure_is_cleaned(self):
        source = self.source.replace('json.dump({"type":', 'json.dump({"unsupported": object(), "type":')
        self.assertNotEqual(source, self.source)
        result = self.run_setup(source=source)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue("JSON serialization" in result.stderr, "serialization diagnostic missing")
        self.assertEqual([record["operation"] for record in self.records()], ["generation", "validation"])

    def test_artifact_directory_is_rejected_as_temporary_parent(self):
        self.environment["ARTIFACT_DIR"] = "/tmp"
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue("temporary directory validation" in result.stderr, "directory diagnostic missing")
        self.assertEqual(self.records(), [])

    def test_term_cleans_up_private_files(self):
        with subprocess.Popen(["bash", "-eu", "-c", self.source], cwd=self.directory,
                              env={**self.environment, "FAIL_STEP": "block"}, start_new_session=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and not any(record["operation"] == "submission" for record in self.records()):
                    time.sleep(0.02)
                self.assertTrue(any(record["operation"] == "submission" for record in self.records()), "stub never ready")
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=10)
                self.assertNotEqual(process.returncode, 0)
                self.assertFalse(any(Path(record["directory"]).exists() for record in self.records()), "private files survived")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()

    def test_signals_during_cleanup_cannot_leave_private_files(self):
        for signal_name in ("SIGINT", "SIGTERM"):
            injected = f'''stage = "temporary directory creation"
original_removal = tempfile.TemporaryDirectory._rmtree.__func__
def interrupt_removal(cls, name, *arguments, **keywords):
    os.kill(os.getpid(), signal.{signal_name})
    return original_removal(cls, name, *arguments, **keywords)
tempfile.TemporaryDirectory._rmtree = classmethod(interrupt_removal)'''
            source = self.source.replace('stage = "temporary directory creation"', injected)
            self.assertNotEqual(source, self.source)
            for failure in ("", "submission"):
                with self.subTest(signal=signal_name, failure=failure):
                    result = self.run_setup(failure, source)
                    self.assertEqual(result.returncode, 1 if failure else 0, "incorrect cleanup outcome")

    def test_consumer_replaces_only_existing_vertex_setup(self):
        source = DEPLOY.read_text(encoding="utf-8")
        self.assertEqual(source.count('"vertex-sa-key"'), 2)
        self.assertNotIn("--from-literal=sa-key.json=", source)
        self.assertLess(source.index("\ncreate_vertex_test_secret\n"),
                        source.index("create secret generic metering-partner-api"))


if __name__ == "__main__":
    unittest.main()
