#!/usr/bin/env python3
"""Offline step regression: python3 hack/test_rosa_ho_deploy_previous_diagnostics.py."""

import json
from contextlib import contextmanager
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/rosa/hypershift-operator/deploy-previous"
SCRIPT = STEP / "rosa-hypershift-operator-deploy-previous-commands.sh"
SENTINEL = "FIXTURE_SECRET_DO_NOT_PRINT"
IMAGE = "quay.io/example/operator@sha256:" + "a" * 64
SELECTOR = "operator-role=control,track in (stable,canary),tier notin (customer),control,!disabled"


def workload(name, uid, owner=None):
    """Build an owned workload with deliberately sensitive fields."""
    resource = {
        "metadata": {"name": name, "uid": uid, "generation": 2,
                     "annotations": {"token": SENTINEL}, "labels": {"private": SENTINEL}},
        "spec": {"replicas": 1, "template": {"spec": {
            "containers": [{"name": "operator", "image": IMAGE,
                            "env": [{"name": "TOKEN", "value": SENTINEL}]}]}}},
        "status": {"observedGeneration": 2, "replicas": 1, "readyReplicas": 0,
                   "conditions": [{"type": "Progressing", "status": "False",
                                   "reason": "ProgressDeadlineExceeded", "message": SENTINEL}]}}
    if owner:
        resource["metadata"]["ownerReferences"] = [{"uid": owner, "controller": True}]
    return resource


def fixture(resource):
    """Return selector and ownership fixtures for the operator."""
    if resource == "deployment":
        result = workload("operator", "deployment-uid")
        result["spec"]["selector"] = {
            "matchLabels": {"operator-role": "control"},
            "matchExpressions": [
                {"key": "track", "operator": "In", "values": ["stable", "canary"]},
                {"key": "tier", "operator": "NotIn", "values": ["customer"]},
                {"key": "control", "operator": "Exists"},
                {"key": "disabled", "operator": "DoesNotExist"}]}
        return result
    if resource == "replicasets":
        return {"items": [workload("operator-rs", "rs-uid", "deployment-uid"),
                          workload("foreign-rs", "foreign-rs-uid", "foreign-deployment")]}
    if resource == "pods":
        result = workload("operator-pod", "pod-uid", "rs-uid")
        result["status"].update({
            "phase": "Pending", "containerStatuses": [{
                "name": "operator", "ready": False, "restartCount": 3, "image": IMAGE,
                "imageID": IMAGE, "containerID": SENTINEL,
                "state": {"waiting": {"reason": "CrashLoopBackOff", "message": SENTINEL}},
                "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137,
                                             "signal": 9, "message": SENTINEL}}}],
            "initContainerStatuses": [{"name": "init", "ready": False,
                                       "state": {"waiting": {"reason": SENTINEL,
                                                              "message": SENTINEL}}}]})
        return {"items": [result, workload("foreign-pod", "foreign-pod-uid", "foreign-rs-uid")]}
    raise AssertionError(resource)


def event_fixture(uid, case):
    """Mix unrelated events with unsorted timestamp fallbacks and unsafe text."""
    items = [{"involvedObject": {"uid": uid}, "type": "Warning", "reason": "FailedMount",
              "message": SENTINEL, "note": SENTINEL, "count": 2}]
    if case == "many-events":
        for index in range(25):
            items.append({"involvedObject": {"uid": uid}, "reason": "FailedMount",
                          "count": index, "lastTimestamp": f"2026-01-01T00:00:{index:02d}Z"})
        for index, fields in enumerate([
                {"series": {"lastObservedTime": "2026-01-01T00:01:00.1Z", "count": 3,
                            "message": SENTINEL}, "lastTimestamp": "2026-01-01T00:00:01Z"},
                {"eventTime": "2026-01-01T00:01:00Z"},
                {"firstTimestamp": "2026-01-01T00:00:59Z"},
                {"metadata": {"creationTimestamp": "2026-01-01T00:00:58Z", "annotations": SENTINEL}},
                {"lastTimestamp": SENTINEL, "eventTime": "2026-01-01T00:00:57Z"},
                {"eventTime": "2026-01-01T00:01:00.01Z"}]):
            items.insert(index * 2, {"involvedObject": {"uid": uid}, "reason": SENTINEL,
                                     "count": 100 + index, "message": SENTINEL, **fields})
    items.insert(0, {"involvedObject": {"uid": "foreign-uid"}, "reason": "foreign-event",
                     "lastTimestamp": "2099-01-01T00:00:00Z"})
    return {"items": items}


def resistant_process(leaf=False):
    """Hold inherited pipes open with a TERM-resistant child and grandchild."""
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with (Path(os.environ["FIXTURE_DIR"]) / "cleanup-pids").open("a", encoding="utf-8") as pids:
        pids.write(str(os.getpid()) + "\n")
    if not leaf:
        with subprocess.Popen([sys.executable, __file__, "--resistant-leaf"]):
            time.sleep(30)
    else:
        time.sleep(30)


@contextmanager
def fixture_process(arguments, environment):
    """Reap the child and kill every process group in its isolated Linux session."""
    process = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        yield process
    finally:
        groups = {process.pid}
        for status in Path("/proc").glob("[0-9]*/stat"):
            try:
                fields = status.read_text(encoding="utf-8").rsplit(") ", 1)[1].split()
                if int(fields[3]) == process.pid:
                    groups.add(int(fields[2]))
            except (FileNotFoundError, ProcessLookupError):
                continue
        for group in groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.stdout.close()
            process.stderr.close()
            process.wait(timeout=5)


def mock_command(command, arguments):
    """Dispatch offline commands without network or cluster access."""
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps([command, arguments, os.environ.get("KUBECONFIG")]) + "\n")
    if command == "ocm":
        if arguments[0] == "login":
            if case in ("harness-timeout", "harness-error"):
                os.setpgrp()
                resistant_process()
            return 0
        if "management_clusters" in arguments[1]:
            print(json.dumps({"items": [{"cluster_management_reference": {"cluster_id": "mock-mc"}}]}))
        elif arguments[1].endswith("/credentials"):
            if case == "missing-kubeconfig":
                (base / "shared/hs-mc.kubeconfig").unlink()
                return 9
            print(json.dumps({"kubeconfig": "" if case == "empty-kubeconfig" else "mock-only"}))
        else:
            print('{"name":"mock-management"}')
        return 0
    if command == "curl":
        print(json.dumps({"tags": [{"name": "latest-1", "manifest_digest": "sha256:" + "b" * 64}]}))
        return 0
    if command == "timeout":
        if arguments[1] == "60s":
            assert arguments[:2] == ["--signal=KILL", "60s"]
            if case == "aggregate-timeout":
                arguments[1] = "1s"
        elif case in ("term-resistant", "term-during-diagnostics"):
            assert arguments[:3] == ["--foreground", "--kill-after=1s", "8s"]
            arguments[2] = "1s"
        os.execv("/usr/bin/timeout", ["timeout", *arguments])
    return mock_oc(arguments, base, case)


def mock_oc(arguments, base, case):
    """Enforce diagnostic request scope and simulate rollout outcomes."""
    if arguments[0].startswith("--kubeconfig="):
        assert arguments[:3] == ["--kubeconfig=" + str(base / "shared/hs-mc.kubeconfig"),
                                 "--request-timeout=5s", "-n"]
        assert arguments[3:5] == ["hypershift", "get"] and arguments[-2:] == ["-o", "json"]
        resource = arguments[5]
        assert resource in ("deployment", "replicasets", "pods", "events")
        if case in ("timeout", "aggregate-timeout", "term-resistant", "term-during-diagnostics"):
            if case in ("term-resistant", "term-during-diagnostics"):
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            (base / "diagnostic.pid").write_text(str(os.getpid()), encoding="utf-8")
            time.sleep(30)
        if case in ("failure-" + resource, "malformed-" + resource):
            failure = case.startswith("failure-")
            print(SENTINEL, file=sys.stderr if failure else sys.stdout)
            return 8 if failure else 0
        if resource == "events":
            uid = arguments[6].removeprefix("--field-selector=involvedObject.uid=")
            assert uid in ("deployment-uid", "rs-uid", "pod-uid") or uid.startswith("old-uid-")
            print(json.dumps(event_fixture(uid, case)))
        else:
            assert arguments[6] == ("operator" if resource == "deployment" else "--selector=" + SELECTOR)
            result = fixture(resource)
            if case == "empty-selector" and resource == "deployment":
                result["spec"]["selector"] = {}
            if case == "invalid-selector" and resource == "deployment":
                result["spec"]["selector"]["matchExpressions"][0]["operator"] = "Unknown"
            if case == "many-replicasets" and resource == "replicasets":
                for index in range(12):
                    historical = workload("old-" + str(index), "old-uid-" + str(index), "deployment-uid")
                    historical["spec"]["replicas"] = 0
                    result["items"].insert(0, historical)
            print(json.dumps(result))
        return 0
    assert os.environ.get("KUBECONFIG") == str(base / "shared/hs-mc.kubeconfig")
    if arguments[:2] == ["get", "configmap"]:
        if case == "locked":
            print("mock-lock")
        return 0
    if arguments[:2] == ["set", "image"]:
        assert arguments == ["set", "image", "deployment/operator", "-n", "hypershift",
                             "operator=quay.io/acm-d/rhtap-hypershift-operator@sha256:" + "b" * 64]
        return 0
    if arguments[:2] == ["rollout", "status"]:
        assert arguments == ["rollout", "status", "deployment/operator", "-n", "hypershift", "--timeout=300s"]
        if case == "remove-kubeconfig":
            (base / "shared/hs-mc.kubeconfig").unlink()
        return 0 if case in ("success", "not-ready") else (124 if case == "exit-124" else 42)
    assert arguments[:5] == ["get", "deployment", "operator", "-n", "hypershift"]
    if "readyReplicas" in arguments[-1]:
        print("0" if case == "not-ready" else "1")
    else:
        print("quay.io/acm-d/rhtap-hypershift-operator@sha256:" + "b" * 64 if case == "no-op" else IMAGE)
    return 0


class DeployPreviousDiagnosticsTest(unittest.TestCase):
    """Exercise the delivered shell script using strict command mocks."""

    def run_case(self, case, expected=42):
        """Run a case with automatically removed temporary artifacts."""
        with tempfile.TemporaryDirectory() as directory:
            return self.run_fixture(case, expected, Path(directory))

    def run_fixture(self, case, expected, base, deadline=75):
        """Run the real script with a bounded lifetime, even on early failures."""
        for directory in ("bin", "shared", "profile", "artifacts"):
            (base / directory).mkdir()
        (base / "profile/ocm-token").write_text("mock-token", encoding="utf-8")
        delivered = base / SCRIPT.name
        shutil.copyfile(SCRIPT, delivered)
        for command in ("oc", "ocm", "curl", "timeout"):
            executable = base / "bin" / command
            executable.write_text(
                "#!" + sys.executable + "\nimport runpy, sys\n"
                + "sys.argv = [" + repr(str(Path(__file__).resolve())) + ", '--mock', "
                + repr(command) + ", *sys.argv[1:]]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n",
                encoding="utf-8")
            executable.chmod(0o755)
        artifacts = base / "artifacts"
        if case == "unavailable-artifacts":
            artifacts.rmdir()
            artifacts.write_text("not a directory", encoding="utf-8")
        environment = {
            "PATH": str(base / "bin") + ":/usr/bin:/bin", "HOME": str(base),
            "FIXTURE_DIR": str(base), "FIXTURE_CASE": case,
            "CLUSTER_PROFILE_DIR": str(base / "profile"), "SHARED_DIR": str(base / "shared"),
            "OCM_LOGIN_ENV": "mock", "CLUSTER_SECTOR": "mock-sector", "REGION": "mock-region",
            "HO_VERSION_OFFSET": "0", "ARTIFACT_DIR": str(artifacts)}
        if case == "unset-artifacts":
            del environment["ARTIFACT_DIR"]
        start = time.monotonic()
        with fixture_process(["bash", str(delivered)], environment) as process:
            if case in ("harness-timeout", "harness-error"):
                ready_deadline = time.monotonic() + 5
                while time.monotonic() < ready_deadline:
                    pids = base / "cleanup-pids"
                    if pids.exists() and len(pids.read_text(encoding="utf-8").splitlines()) == 2:
                        break
                    time.sleep(0.02)
                self.assertTrue(pids.exists())
                self.assertEqual(len(pids.read_text(encoding="utf-8").splitlines()), 2)
                if case == "harness-error":
                    raise AssertionError("injected early failure")
            if case == "term-during-diagnostics":
                ready_deadline = time.monotonic() + 10
                while not (base / "diagnostic.pid").exists() and time.monotonic() < ready_deadline:
                    time.sleep(0.02)
                self.assertTrue((base / "diagnostic.pid").exists())
                process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=deadline)
            result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        calls = [json.loads(line) for line in (base / "calls.jsonl").read_text(encoding="utf-8").splitlines()]
        diagnostics = [arguments for command, arguments, _ in calls
                       if command == "oc" and arguments[0].startswith("--kubeconfig=")]
        files = {path.name: path.read_text(encoding="utf-8") for path in artifacts.rglob("*.json")}
        self.assertNotIn(SENTINEL, result.stdout + result.stderr + "".join(files.values()))
        self.assertNotIn("foreign-", "".join(files.values()))
        mutations = [arguments for command, arguments, _ in calls
                     if command == "oc" and arguments[:2] == ["set", "image"]]
        self.assertEqual(len(mutations), 0 if case in ("no-op", "locked", "missing-kubeconfig") else 1)
        if (base / "diagnostic.pid").exists():
            pid = (base / "diagnostic.pid").read_text(encoding="utf-8")
            process_status = Path("/proc") / pid / "stat"
            self.assertTrue(not process_status.exists() or process_status.read_text(encoding="utf-8").split()[2] == "Z")
        return files, diagnostics, elapsed

    def test_rollout_failure_artifacts(self):
        """Keep structural failure evidence while excluding sensitive fields."""
        files, diagnostics, _ = self.run_case("failure")
        self.assertEqual(len(diagnostics), 6)
        self.assertEqual(set(files), {"deployment.json", "replicasets.json", "pods.json",
                                     "events-deployment-uid.json", "events-rs-uid.json", "events-pod-uid.json"})
        deployment = json.loads(files["deployment.json"])
        self.assertEqual(deployment["status"]["readyReplicas"], 0)
        self.assertEqual(deployment["images"], [{"name": "operator", "image": IMAGE}])
        pod = json.loads(files["pods.json"])[0]
        self.assertFalse(pod["containers"][0]["ready"])
        self.assertEqual(pod["containers"][0]["state"]["waiting"]["reason"], "CrashLoopBackOff")
        self.assertEqual(pod["containers"][0]["lastState"]["terminated"]["exitCode"], 137)
        self.assertEqual(pod["initContainers"][0]["state"]["waiting"]["reason"], "Other")
        self.assertEqual(json.loads(files["events-pod-uid.json"])[0]["reason"], "FailedMount")

    def test_newest_events_survive_cap(self):
        """Sort matching core Events by timestamp fallbacks before limiting."""
        files, _, _ = self.run_case("many-events")
        events = json.loads(files["events-pod-uid.json"])
        self.assertEqual(len(events), 20)
        self.assertEqual([event["count"] for event in events],
                         [100, 105, 101, 102, 103, 104, *range(24, 10, -1)])
        self.assertEqual(events[0]["series"],
                         {"count": 3, "lastObservedTime": "2026-01-01T00:01:00.1Z"})
        self.assertEqual(events[2]["eventTime"], "2026-01-01T00:01:00Z")
        self.assertEqual(events[3]["firstTimestamp"], "2026-01-01T00:00:59Z")
        self.assertEqual(events[4]["creationTimestamp"], "2026-01-01T00:00:58Z")
        self.assertIsNone(events[5]["lastTimestamp"])
        self.assertTrue(all(event["reason"] == "Other" for event in events[:6]))

    def test_harness_cleanup_on_timeout_and_error(self):
        """Kill TERM-resistant descendants on timeout and an early assertion."""
        for case, error in (("harness-timeout", subprocess.TimeoutExpired),
                            ("harness-error", AssertionError)):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                start = time.monotonic()
                message = "injected early failure" if case == "harness-error" else "timed out"
                with self.assertRaisesRegex(error, message):
                    self.run_fixture(case, 42, base, deadline=0.1)
                self.assertLess(time.monotonic() - start, 8)
                for pid in (base / "cleanup-pids").read_text(encoding="utf-8").splitlines():
                    status = Path("/proc") / pid / "stat"
                    self.assertTrue(not status.exists() or
                                    status.read_text(encoding="utf-8").split()[2] == "Z")

    def test_diagnostic_failure_preserves_status(self):
        """Diagnostic API, artifact, and parsing errors preserve rollout status."""
        for case in ("failure-deployment", "failure-replicasets", "failure-pods", "failure-events",
                     "malformed-deployment", "malformed-replicasets", "malformed-pods", "malformed-events",
                     "unavailable-artifacts", "unset-artifacts", "empty-selector", "invalid-selector"):
            with self.subTest(case=case):
                self.run_case(case)
        self.run_case("exit-124", 124)

    def test_timeout_is_bounded(self):
        """Bound an unresponsive diagnostic request."""
        _, diagnostics, elapsed = self.run_case("timeout")
        self.assertEqual(len(diagnostics), 1)
        self.assertLess(elapsed, 15)

    def test_aggregate_deadline_and_term_handling(self):
        """Preserve aggregate deadlines and the original script TERM behavior."""
        communicate = subprocess.Popen.communicate

        def bounded_communicate(process, *arguments, **keywords):
            """Reject absolute timestamps before they can block the harness."""
            self.assertLessEqual(keywords["timeout"], 75)
            return communicate(process, *arguments, **keywords)

        for case in ("aggregate-timeout", "term-resistant", "term-during-diagnostics"):
            with self.subTest(case=case), mock.patch.object(
                    subprocess.Popen, "communicate", bounded_communicate):
                _, diagnostics, elapsed = self.run_case(case)
                self.assertEqual(len(diagnostics), 1)
                self.assertLess(elapsed, 8)

    def test_active_revision_and_pod_events_survive_history_cap(self):
        """Keep active revision and pod evidence despite ReplicaSet history."""
        files, diagnostics, _ = self.run_case("many-replicasets")
        replicasets = json.loads(files["replicasets.json"])
        self.assertEqual(len(replicasets), 10)
        self.assertEqual(replicasets[0]["uid"], "rs-uid")
        self.assertEqual(json.loads(files["pods.json"])[0]["uid"], "pod-uid")
        self.assertIn("events-pod-uid.json", files)
        self.assertEqual(len(diagnostics), 14)

    def test_no_diagnostics_on_success_skip_or_missing_credentials(self):
        """Never collect on success, skip, lock, or missing explicit credentials."""
        for case, expected in (("success", 0), ("no-op", 0), ("locked", 0), ("not-ready", 1),
                               ("missing-kubeconfig", 9), ("empty-kubeconfig", 42),
                               ("remove-kubeconfig", 42)):
            with self.subTest(case=case):
                files, diagnostics, _ = self.run_case(case, expected)
                self.assertFalse(files)
                self.assertFalse(diagnostics)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--resistant-leaf":
        resistant_process(leaf=True)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
