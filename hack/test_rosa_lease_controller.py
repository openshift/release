#!/usr/bin/env python3
"""Offline delivered-command fixtures: python3 hack/test_rosa_lease_controller.py."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STEP = ROOT / "ci-operator/step-registry/rosa/cluster-lease/controller"
CANARY = "fixture-sensitive-response-do-not-publish"


def mock(command, arguments):
    """Record and emulate CLI operations using only local fixture data."""
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    with (base / "calls").open("a", encoding="utf-8") as calls:
        calls.write(command + " " + " ".join(arguments) + "\n")
    if command == "sleep":
        if case in ("term", "int"):
            os.kill(os.getppid(), signal.SIGTERM if case == "term" else signal.SIGINT)
        return 0
    if command == "aws":
        print("000000000000")
    elif command == "rosa":
        if arguments[:2] == ["list", "versions"]:
            print(json.dumps([{"enabled": True, "raw_id": "4.22.1"}]))
        elif case == "create-failure" and arguments[:2] == ["create", "cluster"]:
            return 19
    elif command == "oc":
        if "apply" in arguments:
            manifest = sys.stdin.read()
            if "rosa-cluster-lease/status: available" in manifest:
                with (base / "calls").open("a", encoding="utf-8") as calls:
                    calls.write("available-registration\n")
        elif "rosa-cluster-lease-config" in arguments:
            desired = "- name: first\n  oidc-config-id: fixture\n- name: second\n  oidc-config-id: fixture"
            if case.startswith("cleanup"):
                desired = "- name: first\n  oidc-config-id: fixture"
            print(json.dumps({"data": {"desired-clusters": desired}}))
        elif "get" in arguments:
            items = []
            if case.startswith("cleanup"):
                items = [{"metadata": {"name": "first", "labels": {
                    "rosa-cluster-lease/status": "available"}}, "data": {
                        "cluster-id": "fixture-id", "ocm-env": "staging"}}]
            print(json.dumps({"items": items}))
        else:
            raise AssertionError("Unexpected oc operation")
    elif command == "ocm":
        return mock_ocm(base, case, arguments)
    else:
        raise AssertionError("Unexpected fixture command")
    return 0


def mock_ocm(base, case, arguments):
    """Return canned OCM responses and signal the explicitly identified shell."""
    if arguments[0] == "login":
        if case == "early":
            os.kill(os.getppid(), signal.SIGTERM)
        return 17 if case == "login-failure" else 0
    if arguments[0] != "get":
        raise AssertionError("Unexpected OCM mutation")
    if arguments[1].endswith("/credentials"):
        os.kill(os.getppid(), signal.SIGINT if case == "cleanup-int" else signal.SIGTERM)
        print(json.dumps({"kubeconfig": CANARY}))
        return 0
    if arguments[1].endswith("/fixture-id"):
        print(json.dumps({"id": "fixture-id", "status": {"state": "ready"}}))
        return 0
    name = "first" if "first" in arguments[-1] else "second"
    counter = base / (name + "-lookups")
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count), encoding="utf-8")
    if count == 1:
        print('{"items":[]}')
        return 0
    if case in ("lookup-term", "lookup-int") and name == "first" and count == 3:
        controller_pid = int(os.environ["FIXTURE_CONTROLLER_PID"])
        if controller_pid == os.getppid():
            raise AssertionError("Lookup must run inside a command substitution")
        with (base / "calls").open("a", encoding="utf-8") as calls:
            calls.write(f"lookup-cancel target={controller_pid} parent={os.getppid()}\n")
        os.kill(controller_pid, signal.SIGTERM if case == "lookup-term" else signal.SIGINT)
    state = "ready"
    if name == "first":
        if case in ("term", "int", "exhausted"):
            state = "installing"
        elif case == "error":
            state = "error"
        elif case == "unknown":
            state = CANARY
        elif case == "lookup-failure" and count > 2:
            print(CANARY, file=sys.stderr)
            return 23
    if case in ("malformed", "empty") and count == 3:
        print(CANARY if case == "malformed" else '{"items":[]}')
    else:
        print(json.dumps({"items": [{"id": "fixture-id", "status": {
            "state": state, "description": CANARY}, "openshift_version": "4.22.1",
            "api": {"url": "https://fixture.invalid"}, "credentials": CANARY}]}))
    return 0


class LeaseControllerFixture(unittest.TestCase):
    """Exercise the actual inline controller with isolated, bounded CLI stubs."""

    def run_step(self, case, artifact_mode="normal"):
        """Run a fixture and verify secret exclusion and temporary-file cleanup."""
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            binary = base / "bin"
            binary.mkdir()
            artifacts = base / "artifacts"
            artifacts.mkdir()
            profile = base / "profile"
            profile.mkdir()
            (profile / "ocm-token").write_text(CANARY, encoding="utf-8")
            kubeconfig = base / "kubeconfig"
            kubeconfig.touch()
            for command in ("oc", "ocm", "rosa", "aws", "sleep"):
                stub = binary / command
                stub.write_text(
                    f'#!/bin/bash\nexec "{sys.executable}" -S "{Path(__file__).resolve()}" '
                    f'--mock {command} "$@"\n', encoding="utf-8")
                stub.chmod(0o755)
            ref = (STEP / "rosa-cluster-lease-controller-ref.yaml").read_text(encoding="utf-8")
            filename = next(line.split(": ", 1)[1] for line in ref.splitlines()
                            if line.startswith("  commands: "))
            body = (STEP / filename).read_text(encoding="utf-8")
            body = body.replace("/etc/rosa-cluster-lease-manager/kubeconfig", str(kubeconfig))
            environment = {
                "PATH": str(binary) + os.pathsep + os.defpath,
                "HOME": str(base), "CLUSTER_PROFILE_DIR": str(profile),
                "FIXTURE_DIR": str(base), "FIXTURE_CASE": case, "TMPDIR": str(base),
            }
            if artifact_mode != "unset":
                environment["ARTIFACT_DIR"] = str(artifacts)
            if artifact_mode == "blocked":
                (artifacts / "provisioning-outcomes.jsonl").mkdir()
            prefix = "#!/bin/bash\nset -eu\nexport FIXTURE_CONTROLLER_PID=$$\n"
            with subprocess.Popen(
                    ["/bin/bash", "-c", prefix + body], env=environment,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                try:
                    stdout, stderr = process.communicate(timeout=60)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    raise
                result = subprocess.CompletedProcess(
                    process.args, process.returncode, stdout, stderr)
            artifact_text = "".join(path.read_text(encoding="utf-8")
                                    for path in artifacts.iterdir() if path.is_file())
            self.assertNotIn(CANARY, result.stdout + result.stderr + artifact_text)
            diagnostics = artifacts / "provisioning-outcomes.jsonl"
            records = [json.loads(line) for line in diagnostics.read_text().splitlines()] \
                if diagnostics.is_file() else []
            for record in records:
                self.assertEqual(set(record), {
                    "outcome", "state", "attempts", "elapsed_seconds", "lookup"})
                self.assertGreaterEqual(record["elapsed_seconds"], 0)
            calls = (base / "calls").read_text(encoding="utf-8")
            if case in ("lookup-term", "lookup-int"):
                self.assertIn(f"lookup-cancel target={process.pid} ", calls)
            self.assertFalse(list(base.glob("tmp.*")), "temporary kubeconfig must be removed")
            return result, records, calls

    def test_signals_stop_before_later_operations(self):
        """Signals during the first polling sleep prevent later operations."""
        for case, exit_code in (("term", 143), ("int", 130)):
            with self.subTest(case=case):
                result, records, calls = self.run_step(case)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(records[0]["outcome"], "cancelled")
                self.assertEqual(records[0]["attempts"], 1)
                self.assertEqual(records[0]["state"], "installing")
                self.assertEqual(records[0]["lookup"], "ok")
                self.assertNotIn("--cluster-name second", calls)
                self.assertTrue(calls.rstrip().endswith("sleep 60"), calls)

    def test_lookup_signals_stop_before_later_operations(self):
        """Lookup signals stop the outer shell before its snapshot is updated."""
        for case, exit_code in (("lookup-term", 143), ("lookup-int", 130)):
            with self.subTest(case=case):
                result, records, calls = self.run_step(case)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0], {
                    "outcome": "cancelled", "state": "unknown", "attempts": 1,
                    "lookup": "not_attempted", "elapsed_seconds": records[0]["elapsed_seconds"]})
                before, cancellation = calls.split("lookup-cancel ", 1)
                self.assertIn("--cluster-name first", before)
                self.assertEqual(before.count("rosa create cluster"), 1)
                self.assertEqual(before.count(" apply "), 1)
                self.assertNotIn("--cluster-name second", calls)
                self.assertEqual(len(cancellation.splitlines()), 1)
                target, parent = cancellation.strip().split()
                self.assertNotEqual(target.split("=")[1], parent.split("=")[1])

    def test_early_cancellation_and_optional_context(self):
        """Early cancellation tolerates missing or unusable artifact context."""
        for artifact_mode in ("normal", "unset", "blocked"):
            with self.subTest(artifact_mode=artifact_mode):
                result, records, calls = self.run_step("early", artifact_mode)
                self.assertEqual(result.returncode, 143, result.stderr)
                self.assertNotIn("rosa create", calls)
                if artifact_mode == "normal":
                    self.assertEqual(records[0]["state"], "unknown")
                    self.assertEqual(records[0]["attempts"], 0)
                    self.assertEqual(records[0]["lookup"], "not_attempted")

    def test_existing_exit_cleanup(self):
        """Both signals retain the controller's existing kubeconfig EXIT cleanup."""
        for case, exit_code in (("cleanup", 143), ("cleanup-int", 130)):
            with self.subTest(case=case):
                result, records, _ = self.run_step(case)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                self.assertEqual(records[0]["outcome"], "cancelled")

    def test_transient_invalid_lookup_recovers(self):
        """Malformed or empty lookup data can recover to valid readiness."""
        for case in ("malformed", "empty"):
            with self.subTest(case=case):
                result, records, calls = self.run_step(case)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(records, [])
                self.assertIn("state=unknown (attempt 1/60)", result.stderr)
                self.assertEqual(calls.count("available-registration\n"), 2)

    def test_ready(self):
        """Ready clusters register normally without failure summaries."""
        result, records, calls = self.run_step("ready")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(records, [])
        self.assertIn("--cluster-name second", calls)
        self.assertEqual(calls.count("available-registration\n"), 2)
        self.assertIn("Controller reconcile complete", result.stderr)

    def test_failure_summaries(self):
        """Exhaustion and error summaries retain only normalized fields."""
        for case, state, lookup, attempts, outcome in (
                ("error", "error", "ok", 1, "error"),
                ("exhausted", "installing", "ok", 60, "exhausted"),
                ("unknown", "unknown", "ok", 60, "exhausted"),
                ("lookup-failure", "unknown", "failed", 60, "exhausted")):
            with self.subTest(case=case):
                result, records, _ = self.run_step(case)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0], {
                    "outcome": outcome, "state": state, "lookup": lookup,
                    "attempts": attempts, "elapsed_seconds": records[0]["elapsed_seconds"]})

    def test_collection_failure_does_not_change_result(self):
        """A blocked summary destination does not alter the controller result."""
        result, records, _ = self.run_step("error", "blocked")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(records, [])

    def test_create_failure_not_hidden(self):
        """Create failures remain visible while reconciliation continues."""
        result, records, calls = self.run_step("create-failure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(records, [])
        self.assertIn("Failed to create cluster", result.stderr)
        self.assertIn("--cluster-name second", calls)

    def test_login_failure_status_preserved(self):
        """Authentication failures retain their original nonzero exit status."""
        result, records, calls = self.run_step("login-failure")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(records, [])
        self.assertNotIn("rosa create", calls)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock(sys.argv[2], sys.argv[3:]))
    unittest.main()
