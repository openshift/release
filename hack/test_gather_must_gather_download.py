#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / "ci-operator/step-registry/gather/must-gather/gather-must-gather-commands.sh"
PROXY = "http://fixture-user:fixture-password@proxy.invalid:8080"


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps([command, arguments]) + "\n")
    if command == "sleep":
        return 0
    if command == "curl":
        assert os.environ.get("https_proxy", "") == (
            "" if os.environ["CLUSTER_TYPE"] in ("aws-c2s", "aws-sc2s") else PROXY)
        destination = Path(arguments[arguments.index("--output") + 1])
        assert destination.exists() and destination.stat().st_size == 0
        assert not os.access(destination, os.X_OK)
        assert not (base / "mco-sanitize").exists()
        count_file = base / "count"
        count = int(count_file.read_text()) if count_file.exists() else 0
        count_file.write_text(str(count + 1))
        statuses = json.loads(os.environ["FIXTURE_STATUSES"])
        status = statuses[min(count, len(statuses) - 1)]
        if status:
            destination.write_text("partial binary or HTTP error body")
            print(f"curl: ({status}) fixture download failure", file=sys.stderr)
        else:
            destination.write_text(
                '#!/bin/bash\nprintf sanitized > "${FIXTURE_DIR}/sanitized"\n'
                'exit "${FIXTURE_SANITIZER_STATUS}"\n')
        return status
    if command == "oc":
        assert os.environ["https_proxy"] == PROXY
        assert os.access(base / "mco-sanitize", os.X_OK)
        if "--help" in arguments:
            print("--volume-percentage")
        else:
            output = Path(os.environ["ARTIFACT_DIR"]) / "must-gather"
            resource = output / "cluster-scoped-resources/machineconfiguration.openshift.io"
            resource.mkdir(parents=True)
            (resource / "fixture.yaml").write_text("sensitive fixture")
        return 0
    raise AssertionError(f"Unexpected command: {command}")


class SanitizerDownloadTest(unittest.TestCase):
    def run_case(self, statuses, cluster_type="aws", sanitizer_status=0):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            shared = base / "shared"
            artifacts = base / "artifacts"
            binaries = base / "bin"
            for directory in (shared, artifacts, binaries):
                directory.mkdir()
            kubeconfig = base / "kubeconfig"
            kubeconfig.touch()
            (shared / "proxy-conf.sh").write_text(f"export https_proxy='{PROXY}'\n")
            (shared / "unset-proxy.sh").write_text("unset https_proxy\n")
            (shared / "install-status.txt").write_text("0\n")
            for command in ("curl", "oc", "sleep"):
                wrapper = binaries / command
                wrapper.write_text(
                    f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" '
                    f'--mock {command} "$@"\n')
                wrapper.chmod(0o755)
            script = SCRIPT.read_text().split(
                '[ -f "${ARTIFACT_DIR}/must-gather/event-filter.html" ]', 1)[0]
            script = script.replace("/tmp/mco-sanitize", str(base / "mco-sanitize"))
            environment = {
                "PATH": f"{binaries}:/usr/bin:/bin",
                "SHARED_DIR": str(shared), "ARTIFACT_DIR": str(artifacts),
                "KUBECONFIG": str(kubeconfig), "CLUSTER_TYPE": cluster_type,
                "EXTRA_MG_ARGS": "--fixture-extra", "MUST_GATHER_TIMEOUT": "35m",
                "FIXTURE_DIR": str(base), "FIXTURE_STATUSES": json.dumps(statuses),
                "FIXTURE_SANITIZER_STATUS": str(sanitizer_status),
            }
            result = subprocess.run(["bash", "-c", script], env=environment,
                                    text=True, capture_output=True, timeout=10, check=False)
            calls = [json.loads(line) for line in (base / "calls.jsonl").read_text().splitlines()]
            downloads = [arguments for command, arguments in calls if command == "curl"]
            expected_attempts = next((index + 1 for index, status in enumerate(statuses)
                                      if status == 0), 3)
            self.assertEqual(len(downloads), expected_attempts, result.stderr)
            self.assertEqual(len({arguments[arguments.index("--output") + 1]
                                  for arguments in downloads}), expected_attempts)
            for arguments in downloads:
                for flag in ("--silent", "--show-error", "--fail", "--location"):
                    self.assertIn(flag, arguments)
                for flag, value in (("--connect-timeout", "30"), ("--max-time", "60")):
                    self.assertEqual(arguments[arguments.index(flag) + 1], value)
                self.assertEqual(arguments[-1],
                                 "https://openshift-mirror-list.ci-systems.workers.dev/pub/ci/"
                                 + os.uname().machine + "/mco-sanitize/mco-sanitize")
            self.assertEqual([arguments for command, arguments in calls if command == "sleep"],
                             [[str(5 * attempt)] for attempt in range(1, expected_attempts)])
            self.assertFalse(list(base.glob("mco-sanitize.*")))
            self.assertNotIn("fixture-password", result.stdout + result.stderr)
            self.assertIn("Downloading required mco-sanitize (attempt 1/3)", result.stdout)
            self.assertTrue((artifacts / "junit_install.xml").exists())
            oc_calls = [arguments for command, arguments in calls if command == "oc"]
            if 0 in statuses:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(oc_calls), 2)
                self.assertIn("--timeout=35m", oc_calls[-1])
                self.assertIn("--fixture-extra", oc_calls[-1])
                self.assertIn("--volume-percentage=100", oc_calls[-1])
                self.assertTrue((base / "sanitized").exists())
                self.assertTrue(os.access(base / "mco-sanitize", os.X_OK))
                self.assertIn("Required mco-sanitize download complete.", result.stdout)
                resource = artifacts / "must-gather/cluster-scoped-resources/machineconfiguration.openshift.io"
                if sanitizer_status:
                    self.assertFalse((resource / "fixture.yaml").exists())
                    self.assertEqual((resource / "fixture.yaml.redacted").read_text(), "REDACTED\n")
                else:
                    self.assertEqual((resource / "fixture.yaml").read_text(), "sensitive fixture")
            else:
                self.assertEqual(result.returncode, statuses[-1], result.stderr)
                self.assertFalse(oc_calls)
                self.assertFalse((base / "mco-sanitize").exists())
                self.assertFalse((base / "sanitized").exists())
                self.assertFalse((artifacts / "must-gather").exists())
                self.assertIn("failed after 3 attempts; must-gather will not run", result.stderr)
            for attempt in range(1, expected_attempts + 1):
                status = statuses[min(attempt - 1, len(statuses) - 1)]
                if status:
                    self.assertIn(f"attempt {attempt}/3 failed (curl exit {status})", result.stderr)
                    self.assertIn(f"curl: ({status}) fixture download failure", result.stderr)

    def test_success(self):
        self.run_case([0])

    def test_partial_transfer_retry(self):
        self.run_case([18, 0])

    def test_exhausted_partial_transfers(self):
        self.run_case([18])

    def test_http_failure(self):
        self.run_case([22])

    def test_preserves_final_failure_status(self):
        self.run_case([18, 22, 28])

    def test_proxy_restored(self):
        for cluster_type in ("aws-c2s", "aws-sc2s"):
            with self.subTest(cluster_type=cluster_type):
                self.run_case([18, 0], cluster_type=cluster_type)

    def test_manual_redaction_preserved(self):
        self.run_case([0], sanitizer_status=1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
