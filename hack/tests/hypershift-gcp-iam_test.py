#!/usr/bin/env python3
"""Exercise the real GCP setup/cleanup scripts with no cloud access.

Run with: python3 hack/tests/hypershift-gcp-iam_test.py
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
GCP = ROOT / "ci-operator/step-registry/hypershift/gcp"
SCRIPTS = (
    GCP / "control-plane-setup/hypershift-gcp-control-plane-setup-commands.sh",
    GCP / "gke/deprovision/hypershift-gcp-gke-deprovision-commands.sh",
)
CONFLICT = (
    "ERROR: (gcloud.iam.service-accounts.add-iam-policy-binding) ABORTED: "
    "There were concurrent policy changes. Please retry the whole read-modify-write "
    "with exponential backoff. The request's ETag did not match the current policy's ETag."
)


class IAMRetryTest(unittest.TestCase):
    def run_script(self, script, failures=0, error=CONFLICT, target="external-dns"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "shared"
            shared.mkdir()
            for name, value in {
                "wif-cred.json": "{}",
                "control-plane-project-id": "ci12345678-control-plane",
                "hosted-cluster-project-id": "ci12345678-hosted-cluster",
                "control-plane-cluster-name": "test-gke",
                "gcp-region": "test-region",
                "hosted-cluster-name": "ci123456789ab",
            }.items():
                (shared / name).write_text(value)
            gcloud = root / "gcloud"
            gcloud.write_text(
                "#!/usr/bin/env python3\n"
                "import hashlib, json, os, pathlib, sys\n"
                "root = pathlib.Path(os.environ['MOCK_ROOT'])\n"
                "args = sys.argv[1:]\n"
                "if args[:3] == ['container', 'clusters', 'describe']: sys.exit(1)\n"
                "if not any(x in args for x in ('add-iam-policy-binding', 'remove-iam-policy-binding')): sys.exit(0)\n"
                "with (root / 'calls').open('a') as f: f.write(json.dumps(args) + '\\n')\n"
                "if os.environ['MOCK_TARGET'] != 'all' and not any(x.startswith('--member=serviceAccount:ci12345678-control-plane.svc.id.goog[hypershift/external-dns]') for x in args): sys.exit(0)\n"
                "counter = root / hashlib.sha256(json.dumps(args).encode()).hexdigest()\n"
                "count = int(counter.read_text()) + 1 if counter.exists() else 1\n"
                "counter.write_text(str(count))\n"
                "if count <= int(os.environ['MOCK_FAILURES']):\n"
                " print(os.environ['MOCK_ERROR'], file=sys.stderr)\n"
                " sys.exit(int(os.environ['MOCK_STATUS']))\n"
                "print('POLICY_OUTPUT_SENTINEL')\n"
            )
            sleep = root / "sleep"
            sleep.write_text('#!/bin/bash\nprintf "%s\\n" "$1" >> "${MOCK_ROOT}/delays"\n')
            oc = root / "oc"
            oc.write_text("#!/bin/bash\nexit 0\n")
            for executable in (gcloud, sleep, oc):
                executable.chmod(0o755)
            env = dict(
                os.environ,
                PATH=f"{root}:{os.environ['PATH']}",
                SHARED_DIR=str(shared),
                HYPERSHIFT_GCP_CI_PROJECT="ci-project",
                HYPERSHIFT_GCP_CI_DNS_ZONE="ci-zone",
                MOCK_ROOT=str(root),
                MOCK_FAILURES=str(failures),
                MOCK_ERROR=error,
                MOCK_STATUS="7",
                MOCK_TARGET=target,
            )
            result = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True, timeout=30, check=False)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
            delays = [int(x) for x in (root / "delays").read_text().splitlines()] if (root / "delays").exists() else []
            return result, calls, delays

    def test_immediate_success(self):
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                result, calls, delays = self.run_script(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 4 if script == SCRIPTS[0] else 2)
                self.assertEqual(delays, [])
                self.assertNotIn("POLICY_OUTPUT_SENTINEL", result.stdout + result.stderr)

    def test_conflicts_then_success(self):
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                result, calls, delays = self.run_script(script, failures=4)
                self.assertEqual(result.returncode, 0, result.stderr)
                external = [c for c in calls if "external-dns@ci-project.iam.gserviceaccount.com" in c]
                self.assertEqual(len(external), 10)
                self.assertEqual(len(delays), 8)
                for index, delay in enumerate(delays):
                    self.assertGreaterEqual(delay, 1)
                    self.assertLessEqual(delay, 2 ** (index % 4))
                for offset in (0, 5):
                    self.assertTrue(all(c == external[offset] for c in external[offset:offset + 5]))
                # ExternalDNS calls run with tracing disabled, including inside the helper.
                self.assertNotIn("+ retry_iam_policy_binding gcloud iam service-accounts add-iam-policy-binding external-dns@", result.stderr)
                self.assertNotIn("+ retry_iam_policy_binding gcloud iam service-accounts remove-iam-policy-binding", result.stderr)
                self.assertNotIn("+ error=", result.stderr)

    def test_exhausted_budget(self):
        result, calls, delays = self.run_script(SCRIPTS[0], failures=99)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(len(calls), 7)  # two earlier bindings, five attempts
        self.assertEqual(len(delays), 4)

    def test_all_setup_bindings_retry(self):
        result, calls, delays = self.run_script(SCRIPTS[0], failures=1, target="all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 8)
        self.assertEqual(delays, [1, 1, 1, 1])
        for offset in range(0, 8, 2):
            self.assertEqual(calls[offset], calls[offset + 1])

    def test_non_conflict_errors_are_not_retried(self):
        for error in ("PERMISSION_DENIED", "unrecognized arguments", "UNAVAILABLE", "ABORTED: unrelated failure"):
            with self.subTest(error=error):
                result, calls, delays = self.run_script(SCRIPTS[0], failures=99, error=error)
                self.assertEqual(result.returncode, 7)
                self.assertEqual(len(calls), 3)
                self.assertEqual(delays, [])
                self.assertIn(error, result.stderr)

    def test_cleanup_remains_best_effort(self):
        for error, expected_delays in ((CONFLICT, 8), ("PERMISSION_DENIED", 0)):
            with self.subTest(error=error):
                result, calls, delays = self.run_script(SCRIPTS[1], failures=99, error=error)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(delays), expected_delays)
                self.assertEqual(len(calls), 10 if error == CONFLICT else 2)
                self.assertEqual(result.stderr.count("WARNING: Could not remove ExternalDNS"), 2)
                self.assertIn("Cleanup complete", result.stdout)

    def test_helpers_stay_in_sync(self):
        def helper(script):
            text = script.read_text()
            return text.split("retry_iam_policy_binding() (", 1)[1].split("\n)", 1)[0]

        self.assertEqual(helper(SCRIPTS[0]), helper(SCRIPTS[1]))


if __name__ == "__main__":
    unittest.main()
