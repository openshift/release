#!/usr/bin/env python3

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ("ci-operator/step-registry/rosa/cluster/wait-ready/hosted-cp/"
                 "rosa-cluster-wait-ready-hosted-cp-commands.sh")


class RosaHCPReadinessTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        self.calls = self.directory / "calls"
        self.script = SCRIPT
        self.environment = {
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "SHARED_DIR": str(self.directory),
            "CLUSTER_PROFILE_DIR": str(self.directory),
            "OCM_LOGIN_ENV": "integration",
            "HCP_READY_TIMEOUT": "1800",
            "TEST_DIR": str(self.directory),
            "TEST_MODE": "success",
            "TEST_DIAGNOSTIC_STATUS": "0",
            "TEST_TIMEOUT": shutil.which("timeout"),
            "TEST_SLEEP_STATUS": "0",
            "TEST_API_ERROR": "Forbidden: https://synthetic.invalid token=DO-NOT-PRINT",
        }
        (self.directory / "ocm-token").write_text("synthetic-credential")
        (self.directory / "cluster-id").write_text("test-id")
        self.write_executable("ocm", '''#!/bin/bash
case "$*" in
  login*) ;;
  */credentials) printf '{"kubeconfig":"synthetic-kubeconfig"}' ;;
  */provision_shard) printf '{"management_cluster":"test-management"}' ;;
  *--parameter*) printf '{"items":[{"id":"test-management-id"}]}' ;;
  *) printf '{"name":"test-cluster"}' ;;
esac
''')
        self.write_executable("date", '''#!/bin/bash
if [[ "$*" == "+%s" ]]; then
  clock=$(cat "${TEST_DIR}/clock" 2>/dev/null || echo 0)
  echo "$clock"
  echo "$((clock + 60))" > "${TEST_DIR}/clock"
else
  echo test-time
fi
''')
        self.write_executable("sleep", '''#!/bin/bash
echo "sleep $*" >> "${TEST_DIR}/calls"
exit "${TEST_SLEEP_STATUS}"
''')
        self.write_executable("timeout", '''#!/bin/bash
echo "timeout $*" >> "${TEST_DIR}/calls"
[[ "$1 $2 $3" == "--kill-after=5s 20s oc" ]] || exit 90
shift 2
exec "${TEST_TIMEOUT}" --kill-after=1s 0.2s "$@"
''')
        self.write_executable("oc", r'''#!/bin/bash
echo "oc $*" >> "${TEST_DIR}/calls"
case "$*" in
  whoami) ;;
  *get\ hostedcluster*|*get\ hostedcontrolplane*)
    case "$*" in
      *Degraded*) printf False ;;
      *status.ready*) printf true ;;
      *) printf True ;;
    esac ;;
  *get\ pods*--no-headers*)
    [[ "$*" != *--request-timeout* ]] || exit 91
    if [[ "$TEST_MODE" == api-error ]]; then
      echo "$TEST_API_ERROR" >&2
      exit 7
    fi
    phase=Running
    [[ "$TEST_MODE" == success || "$TEST_MODE" == completed ]] || phase=Pending
    [[ "$TEST_MODE" != completed ]] || phase=Completed
    count=10
    [[ "$TEST_MODE" != too-few ]] || count=9
    echo 'Warning: synthetic API warning' >&2
    for ((index=0; index<count; index++)); do
      echo "test-pod-${index} 0/1 ${phase} 0 1m"
    done ;;
  *get\ pods*'-o wide'*) echo success-pod-list ;;
  *get\ pods*'-o json'*|*get\ events*'-o json'*)
    [[ "$*" == *--request-timeout=15s* ]] || exit 92
    if [[ "$TEST_DIAGNOSTIC_STATUS" == hang ]]; then
      exec /bin/sleep 30
    fi
    if [[ "$TEST_DIAGNOSTIC_STATUS" != 0 ]]; then
      echo 'DO-NOT-PRINT diagnostic error' >&2
      exit "$TEST_DIAGNOSTIC_STATUS"
    fi
    if [[ "$*" == *get\ pods* ]]; then
      cat "${TEST_DIR}/pods.json"
    else
      [[ "$*" == *--field-selector=involvedObject.kind=Pod,type=Warning* ]] || exit 93
      cat "${TEST_DIR}/events.json"
    fi ;;
  *get\ vpcendpoints*) printf available ;;
  *) exit 94 ;;
esac
''')
        container = {
            "name": "test-container", "ready": False, "restartCount": 2,
            "state": {"waiting": {"reason": "CrashLoopBackOff", "message": "DO-NOT-PRINT"}},
            "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137}},
        }
        pod = {
            "metadata": {"name": "test-pod", "annotations": {"token": "DO-NOT-PRINT"}},
            "spec": {"containers": [{"env": [{"value": "DO-NOT-PRINT"}]}]},
            "status": {"phase": "Pending", "conditions": [
                {"type": "Ready", "status": "False", "reason": "ContainersNotReady",
                 "message": "DO-NOT-PRINT"}],
                "containerStatuses": [container], "initContainerStatuses": [container]},
        }
        (self.directory / "pods.json").write_text(json.dumps({"items": [pod]}))
        events = [{"involvedObject": {"name": "test-pod"}, "reason": "FailedScheduling",
                   "message": "DO-NOT-PRINT", "count": 3,
                   "lastTimestamp": f"2026-01-01T00:00:{index:02d}Z"} for index in range(25)]
        (self.directory / "events.json").write_text(json.dumps({"items": events}))

    def write_executable(self, name, content):
        path = self.directory / name
        path.write_text(content)
        path.chmod(0o755)

    def run_script(self, mode, diagnostic_status=0):
        self.environment.update(TEST_MODE=mode, TEST_DIAGNOSTIC_STATUS=str(diagnostic_status))
        result = subprocess.run(["bash", str(self.script)], env=self.environment,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                check=False, timeout=15)
        self.assertNotIn("DO-NOT-PRINT", result.stdout)
        self.assertNotIn("synthetic-credential", result.stdout)
        self.assertNotIn("synthetic-kubeconfig", result.stdout)
        return result

    def test_success_preserves_phase_predicate_and_pod_dump(self):
        result = self.run_script("success")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("success-pod-list", result.stdout)
        self.assertIn("All HostedControlPlane readiness checks passed", result.stdout)
        self.assertNotIn("failure diagnostics", result.stdout)
        self.assertNotIn("get events", self.calls.read_text())

    def test_completed_pods_still_pass(self):
        self.assertEqual(self.run_script("completed").returncode, 0)

    def test_wait_timeout_diagnoses_before_exit(self):
        result = self.run_script("pending")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Timed out after 1800s", result.stdout)
        for expected in ("Pending", "CrashLoopBackOff", "OOMKilled", "ContainersNotReady",
                         '"initContainers"', '"exitCode":137', "FailedScheduling"):
            self.assertIn(expected, result.stdout)
        events = next(json.loads(line) for line in result.stdout.splitlines()
                      if line.startswith('{"warningEvents"'))
        self.assertEqual(len(events["warningEvents"]), 20)
        self.assertEqual(events["warningEvents"][0]["lastObserved"], "2026-01-01T00:00:05Z")
        self.assertEqual(events["warningEvents"][-1]["lastObserved"], "2026-01-01T00:00:24Z")
        calls = self.calls.read_text()
        self.assertEqual(calls.count("sleep 60"), 29)
        self.assertNotIn("get vpcendpoints", calls)
        self.assertNotIn("success-pod-list", result.stdout)

    def test_too_few_pods_still_fail(self):
        self.assertEqual(self.run_script("too-few").returncode, 1)

    def test_api_error_is_sanitized_and_reported_only_once(self):
        for error, category in (("Forbidden", "Forbidden"), ("Unauthorized", "Unauthorized"),
                                ("timed out", "Timeout"), ("x509: failure", "TLS error"),
                                ("no such host", "Connection error"),
                                ("unexpected failure", "API request failed (details omitted)")):
            with self.subTest(category=category):
                self.environment["TEST_API_ERROR"] = f"{error}: https://synthetic.invalid DO-NOT-PRINT"
                (self.directory / "clock").write_text("0")
                self.calls.write_text("")
                result = self.run_script("api-error")
                self.assertEqual(result.returncode, 1, result.stdout)
                expected = f"Last pod-list API error: {category} (exit 7)"
                self.assertEqual(result.stdout.count(expected), 1)
                self.assertNotIn("synthetic.invalid", result.stdout)
                self.assertEqual(self.calls.read_text().count("--no-headers"), 30)

    def test_diagnostic_error_preserves_wait_status(self):
        result = self.run_script("pending", 7)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Pod diagnostics unavailable", result.stdout)
        self.assertIn("Event diagnostics unavailable", result.stdout)

    def test_failed_retry_sleep_preserves_original_status(self):
        self.environment["TEST_SLEEP_STATUS"] = "42"
        result = self.run_script("pending", 7)
        self.assertEqual(result.returncode, 42, result.stdout)
        self.assertIn("failure diagnostics", result.stdout)
        self.assertNotIn("get vpcendpoints", self.calls.read_text())

    def test_api_error_is_safe_with_polling_xtrace_enabled(self):
        self.script = self.directory / "traced-commands.sh"
        self.script.write_text(SCRIPT.read_text().replace(
            "# 3. Check pod status", "set -x\n# 3. Check pod status"))
        result = self.run_script("api-error")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Forbidden (exit 7)", result.stdout)
        self.assertNotIn("synthetic.invalid", result.stdout)

    def test_diagnostic_timeout_preserves_wait_status(self):
        result = self.run_script("pending", "hang")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Pod diagnostics unavailable", result.stdout)
        self.assertIn("Event diagnostics unavailable", result.stdout)

    def test_large_diagnostic_response_is_bounded(self):
        (self.directory / "pods.json").write_text('{"items":[' + ' ' * 1048576)
        result = self.run_script("pending")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Pod diagnostics unavailable", result.stdout)
        self.assertIn("FailedScheduling", result.stdout)
        self.assertLess(len(result.stdout), 20000)

    def test_diagnostic_field_sanitization_and_collection_limits(self):
        fixture = self.directory / "pods.json"
        pod = json.loads(fixture.read_text())["items"][0]
        pod["metadata"]["name"] = "DO-NOT-PRINT"
        pod["status"]["conditions"][0]["reason"] = "DO-NOT-PRINT"
        pod["status"]["conditions"][0]["type"] = "DO-NOT-PRINT"
        pod["status"]["containerStatuses"][0]["name"] = "DO-NOT-PRINT"
        pod["status"]["containerStatuses"][0]["ready"] = "DO-NOT-PRINT"
        pod["status"]["containerStatuses"][0]["restartCount"] = "DO-NOT-PRINT"
        pod["status"]["containerStatuses"][0]["state"]["waiting"]["reason"] = "DO-NOT-PRINT"
        pod["status"]["conditions"] *= 25
        pod["status"]["containerStatuses"] *= 25
        pod["status"]["initContainerStatuses"] *= 25
        other_pod = {"metadata": {"name": "another-pod"}, "status": {"phase": "Pending"}}
        ready_pod = {"metadata": {"name": "ready-pod"}, "status": {"phase": "Running",
                     "conditions": [{"type": "Ready", "status": "True"}]}}
        fixture.write_text(json.dumps({"items": [ready_pod, pod] + [other_pod] * 103}))
        events_path = self.directory / "events.json"
        events = json.loads(events_path.read_text())
        events["items"][-1]["involvedObject"]["name"] = "DO-NOT-PRINT"
        events["items"][-1]["reason"] = "DO-NOT-PRINT"
        events["items"][-1]["count"] = "DO-NOT-PRINT"
        events["items"][-1]["lastTimestamp"] = "DO-NOT-PRINT"
        events_path.write_text(json.dumps(events))
        result = self.run_script("pending")
        self.assertEqual(result.returncode, 1, result.stdout)
        summary = next(json.loads(line) for line in result.stdout.splitlines()
                       if line.startswith('{"totalPods"'))
        self.assertEqual(summary["totalPods"], 105)
        self.assertEqual(len(summary["pods"]), 100)
        self.assertNotIn("Running", [entry["phase"] for entry in summary["pods"]])
        selected = summary["pods"][0]
        for field in ("conditions", "containers", "initContainers"):
            self.assertEqual(len(selected[field]), 20)
        reason = selected["conditions"][0]["reason"]
        self.assertEqual(reason, "Other")
        self.assertEqual(selected["conditions"][0]["type"], "Other")
        self.assertEqual(selected["containers"][0]["waitingReason"], "Other")


if __name__ == "__main__":
    unittest.main()
