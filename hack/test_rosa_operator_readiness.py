#!/usr/bin/env python3
"""Exercise the complete ROSA readiness consumer with offline CLI stubs."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "ci-operator/step-registry/rosa/cluster/wait-ready/operators/rosa-cluster-wait-ready-operators-commands.sh"


class RosaOperatorReadinessTests(unittest.TestCase):
    """Verify readiness, access failures and diagnostics without a cluster."""

    def setUp(self):
        """Create isolated shared files, synthetic credentials and CLI stubs."""
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        self.artifacts = self.directory / "artifacts"
        self.artifacts.mkdir()
        self.config = self.directory / "wrapper-kubeconfig"
        shared_config = self.directory / "kubeconfig"
        shared_config.write_text(json.dumps({"identity": "synthetic-guest-admin"}))
        shutil.copyfile(shared_config, self.config)
        (self.directory / "cluster-config").write_text('{"timers":{}}')
        self.calls = self.directory / "calls"
        self.environment = {
            **os.environ,
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "SHARED_DIR": str(self.directory),
            "ARTIFACT_DIR": str(self.artifacts),
            "CLUSTER_PROFILE_DIR": str(self.directory / "profile"),
            "KUBECONFIG": str(self.config),
            "TEST_DIRECTORY": str(self.directory),
            "TEST_CONFIG": str(self.config),
            "TEST_SCENARIO": "ready",
            "OPERATOR_POLL_INTERVAL": "0",
            "OPERATOR_STALL_TIMEOUT": "1800",
        }
        self.executable("sleep", "#!/bin/bash\nexit 0\n")
        self.executable("date", '''#!/bin/bash
if [[ "$*" == '+%s' ]]; then
    counter="${TEST_DIRECTORY}/clock"
    value=$(cat "${counter}" 2>/dev/null || echo 0)
    echo $((value + 121)) > "${counter}"
    echo "${value}"
else
    echo test-time
fi
''')
        self.executable("oc", '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

directory = Path(os.environ["TEST_DIRECTORY"])
arguments = sys.argv[1:]
with (directory / "calls").open("a") as calls:
    calls.write(json.dumps(arguments) + "\\n")
if os.environ.get("KUBECONFIG") != os.environ["TEST_CONFIG"]:
    sys.exit("wrong guest configuration")
identity = json.loads(Path(os.environ["KUBECONFIG"]).read_text())["identity"]
if identity != "synthetic-guest-admin":
    sys.exit("Error from server (Forbidden): synthetic CI service account")
scenario = os.environ["TEST_SCENARIO"]
if arguments[:2] == ["config", "view"]:
    if scenario == "malformed":
        sys.exit("synthetic-secret: invalid configuration")
    if scenario != "no-server":
        print("https://synthetic-guest.invalid")
    sys.exit(0)
if arguments[:2] != ["get", "clusteroperators"]:
    if scenario == "diagnostic-error":
        sys.exit("synthetic-secret: diagnostic access failed")
    sys.exit(0)
(directory / "identity").write_text(identity)
counter = directory / "queries"
count = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(count))
if scenario in ("forbidden", "unauthorized"):
    reason = scenario.capitalize()
    sys.exit(f"Error from server ({reason}): synthetic-secret")
if scenario == "login-required":
    sys.exit("error: You must be logged in to the server (synthetic-secret)")
if scenario == "retry" and count == 1:
    sys.exit("Unable to connect to the server: synthetic-secret: connection reset")
if scenario == "persistent-transport":
    sys.exit("Unable to connect to the server: synthetic-secret: connection reset")
if scenario == "empty-response" and "-o" in arguments:
    print('{"items": []}')
    sys.exit(0)
if scenario == "invalid-response" and "-o" in arguments:
    print('not JSON')
    sys.exit(0)
if "-o" not in arguments:
    if scenario == "snapshot-error":
        sys.exit("synthetic-secret: snapshot failed")
    print("NAME AVAILABLE PROGRESSING DEGRADED\\nsynthetic True False False")
    sys.exit(0)
progressing = scenario == "stalled" or (scenario in ("progress", "diagnostic-error") and count == 1)
operator = {"metadata": {"name": "synthetic"}, "status": {
    "conditions": [{"type": "Progressing", "status": str(progressing)},
                   {"type": "Available", "status": "True"},
                   {"type": "Degraded", "status": str(scenario == "diagnostic-error" and count == 1)}]}}
if scenario.startswith("pending-"):
    json_counter = directory / "json-queries"
    json_count = int(json_counter.read_text()) + 1 if json_counter.exists() else 1
    json_counter.write_text(str(json_count))
    phase = os.environ.get("TEST_PENDING_PHASE", "Progressing")
    first_phase_query = {"Progressing": 1, "Available": 2, "Degraded": 3}[phase]
    if scenario == "pending-forever" or json_count <= first_phase_query:
        fixture = os.environ["TEST_PENDING_FIXTURE"]
        if fixture == "missing-status":
            operator.pop("status")
        elif fixture == "missing-conditions":
            operator["status"].pop("conditions")
        elif fixture == "null-conditions":
            operator["status"]["conditions"] = None
        elif fixture == "empty-conditions":
            operator["status"]["conditions"] = []
        elif fixture == "missing-requested":
            operator["status"]["conditions"] = [
                condition for condition in operator["status"]["conditions"] if condition["type"] != phase]
if scenario == "malformed-conditions":
    operator["status"]["conditions"] = json.loads(os.environ["TEST_CONDITIONS"])
print(json.dumps({"items": [operator]}))
''')

    def executable(self, name, content):
        """Install a test-owned command ahead of real CLI tools in PATH."""
        path = self.directory / name
        path.write_text(content)
        path.chmod(0o755)

    def run_step(self, scenario="ready"):
        """Run the real script and reject empty artifacts or secret markers."""
        self.environment["TEST_SCENARIO"] = scenario
        result = subprocess.run(
            ["bash", str(SCRIPT)], env=self.environment,
            capture_output=True, text=True, timeout=15, check=False,
        )
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)
        for artifact in self.artifacts.iterdir():
            self.assertTrue(artifact.stat().st_size, artifact.name)
            self.assertNotIn("synthetic-secret", artifact.read_text())
        return result

    def assert_access_failure(self, scenario, expected):
        """Check an immediate failure has a safe diagnostic artifact."""
        result = self.run_step(scenario)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected, result.stdout)
        self.assertIn(expected, (self.artifacts / "co_status.log").read_text())
        self.assertNotIn("within 60m", result.stdout)

    def test_guest_config_and_all_conditions(self):
        """Use the wrapper's private guest config through all three phases."""
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not Progressing, and not Degraded", result.stdout)
        self.assertIn("co_wait_time", (self.directory / "cluster-config").read_text())
        self.assertEqual((self.directory / "identity").read_text(), "synthetic-guest-admin")
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[0][:2], ["config", "view"])
        self.assertIn("--minify", calls[0])

    def test_missing_empty_and_unset_config(self):
        """Reject unusable private configs even if a shared config exists."""
        for state in ("missing", "empty", "unset"):
            with self.subTest(state=state):
                self.config.unlink(missing_ok=True)
                self.calls.unlink(missing_ok=True)
                if state == "empty":
                    self.config.touch()
                if state == "unset":
                    self.environment.pop("KUBECONFIG")
                self.assert_access_failure("ready", "Kubeconfig is missing, empty or unreadable")
                self.assertFalse(self.calls.exists())

    def test_malformed_and_missing_server(self):
        """Reject malformed or server-less kubeconfig before polling."""
        for scenario in ("malformed", "no-server"):
            with self.subTest(scenario=scenario):
                self.assert_access_failure(scenario, "Kubeconfig has no usable current-context server")

    def test_authentication_and_authorization_fail_fast(self):
        """Stop after one operator query on deterministic access denials."""
        for scenario in ("forbidden", "unauthorized", "login-required"):
            with self.subTest(scenario=scenario):
                (self.directory / "queries").unlink(missing_ok=True)
                self.assert_access_failure(scenario, "Cluster operator query denied")
                self.assertEqual((self.directory / "queries").read_text(), "1")

    def test_retryable_transport_error_recovers(self):
        """Retry transient transport errors and observe later readiness."""
        result = self.run_step("retry")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("will retry", result.stdout)
        self.assertIn("retryable or unclassified", (self.artifacts / "co_query.log").read_text())

    def test_operator_progress_is_still_polled(self):
        """Keep genuinely progressing operators in the polling loop."""
        result = self.run_step("progress")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 operator(s)", result.stdout)

    def test_transport_timeout_is_not_reported_as_operator_failure(self):
        """Distinguish persistent transport failure from operator failure."""
        result = self.run_step("persistent-transport")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("query unavailable at timeout", result.stdout)
        self.assertNotIn("not done progressing within", result.stdout)
        self.assertGreater(int((self.directory / "queries").read_text()), 1)

    def test_real_operator_stall_still_fails(self):
        """Bound a stable not-ready operator set using stall detection."""
        self.environment["OPERATOR_STALL_TIMEOUT"] = "1"
        result = self.run_step("stalled")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stalled", result.stdout)

    def test_empty_operator_response_is_not_ready(self):
        """Reject empty lists and malformed JSON rather than declaring ready."""
        for scenario in ("empty-response", "invalid-response"):
            with self.subTest(scenario=scenario):
                result = self.run_step(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid or empty cluster operator response", result.stdout)

    def test_missing_conditions_remain_pending(self):
        """Poll incomplete status until it becomes ready or genuinely stalls."""
        for fixture in ("missing-status", "missing-conditions", "null-conditions",
                        "empty-conditions", "missing-requested"):
            for scenario in ("pending-eventual", "pending-forever"):
                with self.subTest(fixture=fixture, scenario=scenario):
                    for counter in ("queries", "json-queries", "clock"):
                        (self.directory / counter).unlink(missing_ok=True)
                    self.environment["TEST_PENDING_FIXTURE"] = fixture
                    self.environment["OPERATOR_STALL_TIMEOUT"] = "1"
                    result = self.run_step(scenario)
                    self.assertGreater(int((self.directory / "json-queries").read_text()), 1)
                    self.assertNotIn("Invalid or empty cluster operator response", result.stdout)
                    self.assertIn("1 operator(s)", result.stdout)
                    if scenario == "pending-eventual":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("stalled", result.stdout)

    def test_missing_requested_condition_in_later_phases(self):
        """Apply pending semantics during Available and Degraded checks too."""
        for phase in ("Available", "Degraded"):
            for scenario in ("pending-eventual", "pending-forever"):
                with self.subTest(phase=phase, scenario=scenario):
                    for counter in ("queries", "json-queries", "clock"):
                        (self.directory / counter).unlink(missing_ok=True)
                    self.environment["TEST_PENDING_FIXTURE"] = "missing-requested"
                    self.environment["TEST_PENDING_PHASE"] = phase
                    self.environment["OPERATOR_STALL_TIMEOUT"] = "1"
                    result = self.run_step(scenario)
                    self.assertIn(f"{phase}=", result.stdout)
                    self.assertNotIn("Invalid or empty cluster operator response", result.stdout)
                    self.assertGreater(int((self.directory / "json-queries").read_text()),
                                       {"Available": 2, "Degraded": 3}[phase])
                    if scenario == "pending-eventual":
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("stalled", result.stdout)

    def test_malformed_condition_shapes_and_statuses_are_rejected(self):
        """Keep malformed types and invalid requested statuses fail-fast."""
        fixtures = ["bad", {}, 1, False, [None], ["bad"], [[]],
                    [{"type": 1, "status": "True"}], [{"status": "True"}]]
        fixtures.extend([[{"type": "Progressing", "status": status}]
                         for status in (None, "invalid", "", 1, False, [])])
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                self.environment["TEST_CONDITIONS"] = json.dumps(fixture)
                self.assert_access_failure("malformed-conditions", "Invalid or empty cluster operator response")

    def test_failed_diagnostics_do_not_claim_no_resources(self):
        """Report failed pod/event queries instead of claiming no resources."""
        result = self.run_step("diagnostic-error")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("pod query failed", result.stdout)
        self.assertIn("event query failed", result.stdout)

    def test_snapshot_failure_has_nonempty_safe_artifact(self):
        """Write an explicit unavailable-status artifact on snapshot failure."""
        result = self.run_step("snapshot-error")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Failed to query clusteroperators", (self.artifacts / "co_status.log").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
