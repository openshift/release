#!/usr/bin/env python3
"""Offline tests of the remote timeout, stop and credential cleanup contract.

These execute the actual embedded scripts against temporary files/processes.
They never connect to a host or invoke Ansible/Terraform.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1] / "ci-operator/step-registry/assisted/qe"


def script(phase):
    return (ROOT / phase / f"assisted-qe-{phase}-commands.sh").read_text()


def heredoc(text, delimiter):
    match = re.search(r"<<'" + delimiter + r"'[^\n]*\n(.*?)\n" + delimiter + r"\n", text, re.S)
    if not match:
        raise AssertionError(f"Missing {delimiter} heredoc")
    return match.group(1) + "\n"


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.reports = self.work / "reports"
        self.reports.mkdir()

    def test_host_timeout_returns_failure_and_removes_pid(self):
        (self.work / "test.sh").write_text("sleep 30\n")
        result = subprocess.run(["bash", "-s", "--", str(self.work), "test", "0.2s"],
                                input=heredoc(script("setup"), "SUPERVISOR"),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertFalse((self.work / "active.pid").exists())

    def test_post_stops_disconnected_remote_phase(self):
        phase = self.work / "test.sh"
        phase.write_text("sleep 30\n")
        process = subprocess.Popen(["timeout", "60", "bash", str(phase)], start_new_session=True)
        (self.work / "active.pid").write_text(str(process.pid) + "\n")
        try:
            result = subprocess.run(["bash", "-s", "--", str(self.work)],
                                    input='sudo() { shift; command "$@"; }\n' + heredoc(script("setup"), "STOP"),
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNotNone(process.poll())
            self.assertFalse((self.work / "active.pid").exists())
        finally:
            if process.poll() is None:
                os.killpg(process.pid, 9)
            process.wait()

    def test_shell_syntax_including_embedded_scripts(self):
        for phase in ("setup", "provision", "test", "gather", "release"):
            code = script(phase)
            snippets = [code]
            for marker in ("HELPER", "REMOTE", "SUPERVISOR", "STOP"):
                snippets.extend(re.findall(r"<<'" + marker + r"'[^\n]*\n(.*?)\n" + marker + r"\n", code, re.S))
            for snippet in snippets:
                result = subprocess.run(["bash", "-n"], input=snippet, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, f"{phase}: {result.stderr}")

    def test_release_removes_credentials_even_if_archiving_fails(self):
        (self.work / 'secrets').mkdir()
        (self.work / 'secrets/vault').write_text('fixture')
        (self.work / 'job.env').write_text('fixture')
        (self.work / 'logs').mkdir()
        (self.work / 'logs/test.log').write_text('fixture')
        blocks = re.findall(r"<<'REMOTE'[^\n]*\n(.*?)\nREMOTE\n", script('release'), re.S)
        # Redirect only the archive path to this test's temp directory. The real
        # cleanup trap runs, while sudo/copy failure is simulated without privilege.
        archive = str(Path(self.tmp.name) / 'archive')
        code = blocks[-1].replace('archive="$HOME/prow-assisted-qe/artifacts/${work##*/}"',
                                  'archive=' + archive)
        result = subprocess.run(['bash', '-s', '--', str(self.work)],
                                input='sudo() { return 1; }\n' + code, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.work.exists())


if __name__ == "__main__":
    unittest.main()
