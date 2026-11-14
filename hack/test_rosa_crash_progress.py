#!/usr/bin/env python3

"""Offline regressions executing the real ROSA operator readiness entry point."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ("ci-operator/step-registry/rosa/cluster/wait-ready/operators/"
                 "rosa-cluster-wait-ready-operators-commands.sh")


class CrashProgressHarness(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        (self.directory / "artifacts").mkdir()
        (self.directory / "cluster-config").write_text('{"timers":{}}')
        (self.directory / "clock").write_text("0")
        self.environment = {
            "PATH": f"{self.directory}:{os.environ['PATH']}",
            "SHARED_DIR": str(self.directory),
            "ARTIFACT_DIR": str(self.directory / "artifacts"),
            "CLUSTER_PROFILE_DIR": str(self.directory),
            "TEST_DIR": str(self.directory),
            "TEST_MODE": "restart",
            "OPERATOR_POLL_INTERVAL": "120",
            "OPERATOR_STALL_TIMEOUT": "7200",
        }
        self.output = ""
        self._write_executable("date", '''#!/bin/bash
if [[ "$*" == '+%s' ]]; then cat "${TEST_DIR}/clock"; else echo 20260101; fi
''')
        self._write_executable("sleep", '''#!/bin/bash
clock=$(cat "${TEST_DIR}/clock")
echo $((clock + $1)) > "${TEST_DIR}/clock"
''')
        self._write_executable("oc", '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
root = Path(os.environ["TEST_DIR"])
args = sys.argv[1:]
clock = int((root / "clock").read_text())
iteration = clock // 120
mode = os.environ["TEST_MODE"]
ready_at = int(os.environ.get("TEST_READY_AT", "-1"))
with (root / "calls").open("a") as output:
    output.write(json.dumps(args) + "\\n")
if args[:2] == ["get", "clusteroperators"]:
    if "json" not in args:
        print("console False False False")
    else:
        if mode == "operator-query-failure" and iteration == 1:
            sys.exit(1)
        ready = mode == "healthy" or (mode in ["restart", "replacement", "container-id", "init", "ephemeral", "late", "late-replacement"] and iteration >= 3) or (ready_at >= 0 and clock >= ready_at)
        print(json.dumps({"items": [{"metadata": {"name": "console"}, "status": {"conditions": [
            {"type": "Progressing", "status": "False" if ready else "True"},
            {"type": "Available", "status": "True" if ready else "False"},
            {"type": "Degraded", "status": "False"}]}}]}))
elif args[:2] == ["get", "pods"]:
    if mode == "query-failure" and iteration == 1:
        sys.exit(1)
    if mode == "query-always-fails":
        sys.exit(1)
    if clock == int(os.environ.get("TEST_QUERY_FAILURE_AT", "-1")):
        sys.exit(1)
    if mode == "malformed":
        print("{}"); sys.exit(0)
    if "json" not in args:
        print(f"console-pod 0/1 CrashLoopBackOff {iteration + 1} 1m")
    else:
        restarts = iteration + 1 if mode in ["restart", "endless", "init", "ephemeral", "late"] else 1
        if mode == "backoff":
            restarts = clock // 360 + 1
        status = {"name": "console", "ready": False, "restartCount": restarts,
                  "containerID": "cri://" + str(iteration if mode == "container-id" else 1),
                  "state": {"waiting": {"reason": "CrashLoopBackOff", "message": "SECRET_SENTINEL"}},
                  "lastState": {"terminated": {"reason": "Error", "exitCode": 1, "signal": 0,
                      "finishedAt": "2026-01-01T00:00:00Z", "message": "SECRET_SENTINEL"}}}
        statuses = "initContainerStatuses" if mode == "init" else "ephemeralContainerStatuses" if mode == "ephemeral" else "containerStatuses"
        if mode == "missing-counter":
            del status["restartCount"]
        if mode == "no-crashes" or (mode in ["late", "late-replacement"] and iteration == 0):
            status["state"] = {"running": {}}
        pods = [{"metadata": {"name": "console-pod", "uid": str(iteration if mode in ["replacement", "late-replacement"] else 1)},
                 "spec": {"secret": "SECRET_SENTINEL"}, "status": {statuses: [status]}}]
        if mode == "reordered":
            pods.append({"metadata": {"name": "other", "uid": "other"}, "status": {"containerStatuses": [dict(status, name="other")]}})
            if iteration % 2:
                pods.reverse()
        if mode == "multi":
            pods.append({"metadata": {"name": "other-pod", "uid": "2"}, "status": {
                "containerStatuses": [dict(status, name="other")]}})
            if iteration % 2:
                pods.reverse()
        if mode in ["many", "budget"]:
            pods *= 50
        if mode == "missing-status":
            pods[0]["status"] = {}
        if mode == "mixed-pending" or (mode == "pending-reset" and clock == 360):
            pods.append({"metadata": {"name": "pending-pod", "uid": "pending"}, "status": {"phase": "Pending"}})
        if mode == "malformed-status":
            pods[0]["status"]["containerStatuses"] = {}
        if mode == "unsafe-identity":
            pods[0]["metadata"] = {"name": "https://SECRET_SENTINEL", "uid": "Bearer SECRET_SENTINEL"}
            status["name"] = "SECRET_SENTINEL" * 100
        print(json.dumps({"items": pods}))
elif args[:2] == ["get", "events"]:
    if "json" in args:
        print(json.dumps({"items": [{"reason": "BackOff", "count": 3, "message": "SECRET_SENTINEL"}] * 100}))
elif args[:1] == ["logs"]:
    if mode == "budget":
        (root / "clock").write_text(str(clock + 5))
    if mode == "diagnostic-failure":
        print("SECRET_SENTINEL", file=sys.stderr); sys.exit(1)
    if mode == "diagnostic-slow":
        (root / "clock").write_text(str(clock + 5))
        if not (root / "slow-log-seen").exists():
            (root / "slow-log-seen").touch()
            import time
            time.sleep(20)
        sys.exit(1)
    if mode == "logs-small":
        print("panic: SECRET_SENTINEL\\nAuthorization: Bearer SECRET_SENTINEL")
        sys.exit(0)
    print("panic: SECRET_SENTINEL\\nAuthorization: Bearer SECRET_SENTINEL\\n" * 10000)
else:
    sys.exit(99)
''')

    def _write_executable(self, name, contents):
        path = self.directory / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def run_step(self, mode, **environment):
        result = subprocess.run(
            ["bash", str(SCRIPT)], env={**self.environment, "TEST_MODE": mode, **environment},
            capture_output=True, text=True, check=False, timeout=25,
        )
        self.output = result.stdout + result.stderr
        return result


class CrashProgressTests(CrashProgressHarness):
    def test_advancing_restarts_reach_readiness(self):
        result = self.run_step("restart")
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn("All cluster operators are Available", self.output)

    def test_replacement_reaches_readiness(self):
        self.assertEqual(self.run_step("replacement").returncode, 0, self.output)

    def test_container_identity_progress(self):
        self.assertEqual(self.run_step("container-id").returncode, 0, self.output)

    def test_init_restart_progress(self):
        self.assertEqual(self.run_step("init").returncode, 0, self.output)

    def test_ephemeral_restart_progress(self):
        self.assertEqual(self.run_step("ephemeral").returncode, 0, self.output)

    def test_static_crash_fails_early(self):
        self.assertEqual(self.run_step("static").returncode, 1, self.output)
        self.assertIn("no restart progress", self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "480")

    def test_order_is_not_progress(self):
        self.assertEqual(self.run_step("reordered").returncode, 1, self.output)
        self.assertIn("no restart progress", self.output)

    def test_absolute_timeout_despite_restarts(self):
        self.assertEqual(self.run_step("endless").returncode, 1, self.output)
        self.assertNotIn("no restart progress", self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "3600")

    def test_existing_stall_is_preserved(self):
        self.assertEqual(self.run_step("endless", OPERATOR_STALL_TIMEOUT="240").returncode, 1)
        self.assertIn("stalled for", self.output)

    def test_query_failure_breaks_stationary_evidence(self):
        self.assertEqual(self.run_step("query-failure").returncode, 1, self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "720")

    def test_unknown_queries_never_claim_stationary(self):
        for mode in ["query-always-fails", "malformed", "missing-counter", "missing-status", "no-crashes"]:
            with self.subTest(mode=mode):
                (self.directory / "clock").write_text("0")
                self.assertEqual(self.run_step(mode).returncode, 1, self.output)
                self.assertNotIn("no restart progress", self.output)
                self.assertIn("within 60m", self.output)

    def test_healthy_needs_no_crash_diagnostics(self):
        self.assertEqual(self.run_step("healthy").returncode, 0, self.output)
        self.assertFalse(list((self.directory / "artifacts").glob("crash*")))

    def test_diagnostic_failure_does_not_change_decision(self):
        self.assertEqual(self.run_step("diagnostic-failure").returncode, 1, self.output)
        self.assertIn("no restart progress", self.output)
        self.assertNotIn("SECRET_SENTINEL", self.output)

    def test_operator_query_failure_breaks_stationary_evidence(self):
        self.assertEqual(self.run_step("operator-query-failure").returncode, 1, self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "720")

    def test_diagnostic_commands_are_time_bounded(self):
        self.assertEqual(self.run_step("diagnostic-slow").returncode, 1, self.output)
        self.assertIn("no restart progress", self.output)

    def test_log_summaries_never_persist_arbitrary_content(self):
        self.assertEqual(self.run_step("logs-small").returncode, 1, self.output)
        logs = list((self.directory / "artifacts").glob("crash*/*.log"))
        self.assertTrue(logs)
        for path in logs:
            content = path.read_text()
            self.assertIn("panic: [content omitted]", content)
            self.assertNotIn("SECRET_SENTINEL", content)

    def test_container_capture_count_is_bounded(self):
        self.assertEqual(self.run_step("many").returncode, 1, self.output)
        captures = list((self.directory / "artifacts").glob("crash*"))
        self.assertEqual(len(captures), 5)
        for capture in captures:
            self.assertLessEqual(len(list(capture.glob("*.log"))), 8)

    def test_early_bounded_sanitized_artifacts(self):
        self.assertEqual(self.run_step("endless").returncode, 1, self.output)
        files = list((self.directory / "artifacts").glob("crash*/*"))
        self.assertTrue(files)
        self.assertTrue(any("Progressing-1-" in str(path) for path in files))
        self.assertLessEqual(len(files), 8 * 10)
        for path in files:
            self.assertLessEqual(path.stat().st_size, 65536)
            self.assertNotIn("SECRET_SENTINEL", path.read_text())
        calls = (self.directory / "calls").read_text()
        self.assertIn('"--previous"', calls)
        self.assertIn('"--tail=100"', calls)
        self.assertIn('"--limit-bytes=16384"', calls)


class LateCrashProgressTests(CrashProgressHarness):
    def test_multiple_log_indices_match_requested_identities(self):
        self.assertEqual(self.run_step("multi").returncode, 1, self.output)
        files = sorted((self.directory / "artifacts").glob("crash*/status.json"))
        calls = [json.loads(line) for line in (self.directory / "calls").read_text().splitlines()]
        logs = [arguments for arguments in calls if arguments[0] == "logs"]
        self.assertEqual(len(files), 5)
        self.assertEqual(len(logs), 20)
        for capture, path in enumerate(files):
            metadata = json.loads(path.read_text())
            self.assertEqual([(entry["pod"], entry["container"]) for entry in metadata], [
                ("console-pod", "console"), ("other-pod", "other"),
            ])
            for index, entry in enumerate(metadata):
                self.assertEqual(entry["index"], index)
                for offset, stream in enumerate(["previous", "current"]):
                    arguments = logs[capture * 4 + index * 2 + offset]
                    self.assertEqual(arguments[1], entry["pod"])
                    self.assertEqual(arguments[arguments.index("-c") + 1], entry["container"])
                    self.assertEqual(arguments[arguments.index("-n") + 1], entry["namespace"])
                    self.assertEqual("--previous" in arguments, stream == "previous")
                    self.assertTrue((path.parent / f"container-{index}-{stream}.log").is_file())

    def test_artifacts_correlate_logs_to_selected_identities(self):
        self.assertEqual(self.run_step("replacement").returncode, 0, self.output)
        files = sorted((self.directory / "artifacts").glob("crash*/status.json"))
        self.assertEqual(len(files), 3)
        for iteration, path in enumerate(files):
            metadata = json.loads(path.read_text())
            self.assertEqual(len(metadata), 1)
            self.assertEqual({key: metadata[0][key] for key in [
                "index", "operator", "namespace", "pod", "podUID", "container",
            ]}, {
                "index": 0, "operator": "console", "namespace": "openshift-console",
                "pod": "console-pod", "podUID": str(iteration), "container": "console",
            })
            self.assertEqual(metadata[0]["lastTermination"]["exitCode"], 1)
            self.assertTrue((path.parent / "container-0-previous.log").is_file())
            self.assertTrue((path.parent / "container-0-current.log").is_file())
            self.assertLessEqual(path.stat().st_size, 65536)
            self.assertNotIn("SECRET_SENTINEL", path.read_text())

    def test_invalid_identity_metadata_is_omitted(self):
        self.assertEqual(self.run_step("unsafe-identity").returncode, 1, self.output)
        files = list((self.directory / "artifacts").glob("crash*/status.json"))
        self.assertTrue(files)
        for path in files:
            metadata = json.loads(path.read_text())[0]
            for key in ["pod", "podUID", "container"]:
                self.assertEqual(metadata[key], "[omitted]")
            self.assertEqual(metadata["namespace"], "openshift-console")
            self.assertNotIn("SECRET_SENTINEL", path.read_text())
        for path in (self.directory / "artifacts").glob("crash*/*"):
            self.assertNotIn("SECRET_SENTINEL", path.read_text())
        self.assertNotIn("SECRET_SENTINEL", self.output)

    def test_late_onset_and_replacement_are_captured(self):
        for mode in ["late", "late-replacement"]:
            with self.subTest(mode=mode):
                (self.directory / "clock").write_text("0")
                shutil.rmtree(self.directory / "artifacts")
                (self.directory / "artifacts").mkdir()
                self.assertEqual(self.run_step(mode).returncode, 0, self.output)
                files = list((self.directory / "artifacts").glob("crash-Progressing-[23]-*/*.log"))
                self.assertEqual(len(files), 4)

    def test_events_precede_slow_logs_and_budget_is_shared(self):
        self.assertEqual(self.run_step("budget").returncode, 1, self.output)
        calls = (self.directory / "calls").read_text().splitlines()
        event_calls = [index for index, call in enumerate(calls) if '"events"' in call and '"json"' in call]
        log_calls = [index for index, call in enumerate(calls) if '"logs"' in call]
        self.assertEqual(len(event_calls), 1)
        self.assertEqual(len(log_calls), 8)
        self.assertLess(event_calls[0], log_calls[0])
        self.assertIn('"--previous"', calls[log_calls[0]])


class BackoffObservationTests(CrashProgressHarness):
    """Distinguish incomplete sampling and normal restart backoff from stagnation."""

    def test_mixed_pending_preserves_diagnostics_without_stagnation(self):
        self.assertEqual(self.run_step("mixed-pending").returncode, 1, self.output)
        self.assertNotIn("no restart progress", self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "3600")
        files = list((self.directory / "artifacts").glob("crash*/status.json"))
        self.assertTrue(files, "A Pending sibling must not hide observed crash diagnostics")
        self.assertEqual(json.loads(files[0].read_text())[0]["pod"], "console-pod")

    def test_identical_backoff_observations_then_restart_and_success(self):
        self.assertEqual(self.run_step("backoff", TEST_READY_AT="720").returncode, 0, self.output)
        self.assertNotIn("no restart progress", self.output)

    def test_strict_elapsed_boundary_for_different_poll_intervals(self):
        for poll in [60, 100, 120, 300, 600, 1000]:
            with self.subTest(poll=poll):
                (self.directory / "clock").write_text("0")
                self.assertEqual(self.run_step("static", OPERATOR_POLL_INTERVAL=str(poll)).returncode, 1)
                expected = ((300 + poll) // poll + 1) * poll
                self.assertEqual(int((self.directory / "clock").read_text()), expected, self.output)

    def test_long_poll_can_observe_success_after_identical_checks(self):
        self.assertEqual(self.run_step("static", OPERATOR_POLL_INTERVAL="600", TEST_READY_AT="1200").returncode, 0, self.output)

    def test_query_failure_restarts_elapsed_evidence(self):
        self.assertEqual(self.run_step("static", TEST_QUERY_FAILURE_AT="360").returncode, 1, self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "960")

    def test_pending_pod_restarts_elapsed_evidence(self):
        self.assertEqual(self.run_step("pending-reset").returncode, 1, self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "960")

    def test_malformed_status_remains_unknown_not_stationary(self):
        self.assertEqual(self.run_step("malformed-status").returncode, 1, self.output)
        self.assertNotIn("no restart progress", self.output)
        self.assertFalse(list((self.directory / "artifacts").glob("crash*")))

    def test_normal_backoff_activity_cannot_extend_absolute_timeout(self):
        self.assertEqual(self.run_step("backoff").returncode, 1, self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "3600")
        self.assertNotIn("no restart progress", self.output)

    def test_long_poll_window_cannot_override_absolute_timeout(self):
        self.assertEqual(self.run_step("static", OPERATOR_POLL_INTERVAL="1800").returncode, 1, self.output)
        self.assertEqual((self.directory / "clock").read_text().strip(), "3600")
        self.assertNotIn("no restart progress", self.output)


if __name__ == "__main__":
    unittest.main()
