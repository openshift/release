#!/usr/bin/env python3
"""Offline recovery fixtures: python3 hack/test_rosa_cluster_lease_health.py."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


STEP = (Path(__file__).resolve().parents[1] / "ci-operator/step-registry/rosa/cluster-lease/health"
        / "rosa-cluster-lease-health-commands.sh")
PREFIX = "rosa-cluster-lease/"
SENSITIVE_OUTPUT = "fixture-sensitive-output"


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    settings = json.loads((base / "settings.json").read_text(encoding="utf-8"))
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps([command, *arguments]) + "\n")
    if command == "ocm":
        return mock_ocm(arguments, settings)
    assert command == "oc"
    if arguments[0] == "--kubeconfig=" + str(base / "host-kubeconfig"):
        return mock_lease_oc(arguments, base)
    return mock_cluster_oc(arguments, base, settings)


def mock_ocm(arguments, settings):
    if arguments[0] == "login":
        return 0
    if arguments[0] == "get" and arguments[1].endswith("/credentials"):
        print(settings.get("credentials", json.dumps({"kubeconfig": SENSITIVE_OUTPUT})))
        print(SENSITIVE_OUTPUT, file=sys.stderr)
        return settings.get("credentials_exit", 0)
    if arguments[0] == "get":
        print(json.dumps({"status": {"state": settings.get("ocm_status", "ready")}}))
        return 0
    raise AssertionError(f"Unexpected mock OCM command: {arguments}")


def mock_lease_oc(arguments, base):
    if arguments[1:4] == ["get", "configmap", "rosa-cluster-lease-config"]:
        print("rbac-permissions-operator")
        return 0
    if arguments[1:3] == ["get", "configmap"]:
        print((base / "inventory.json").read_text(encoding="utf-8"))
        return 0
    if arguments[1:3] == ["patch", "configmap"]:
        patch = json.loads(arguments[arguments.index("-p") + 1])
        inventory = json.loads((base / "inventory.json").read_text(encoding="utf-8"))
        cluster = next(item for item in inventory["items"]
                       if item["metadata"]["name"] == arguments[3])
        for field, values in patch["metadata"].items():
            cluster["metadata"][field].update(values)
        (base / "inventory.json").write_text(json.dumps(inventory), encoding="utf-8")
        return 0
    raise AssertionError(f"Unexpected mock lease command: {arguments}")


def mock_cluster_oc(arguments, base, settings):
    kubeconfig = next(value.split("=", 1)[1] for value in arguments
                      if value.startswith("--kubeconfig="))
    assert Path(kubeconfig).read_text(encoding="utf-8").strip() == SENSITIVE_OUTPUT
    if arguments[1:3] == ["get", "clusterpackage"]:
        if settings.get("cp_unavailable"):
            return 1
        print(json.dumps({"items": [{"metadata": {"name": "rbac-permissions-operator"},
                                    "status": {"conditions": [{"type": "Available",
                                        "status": settings.get("cp_available", "True")}]
                                               }}]}))
        return 0
    if arguments[:5] == ["auth", "can-i", "create", "configmaps", "--as=dedicated-admin-check"]:
        assert "--as-group=dedicated-admins" in arguments
        assert arguments[arguments.index("-n") + 1] == "dedicated-admin"
        assert "--request-timeout=30s" in arguments
        results = settings.get("rbac_results", [settings.get("rbac_result", "yes")])
        calls = [json.loads(line) for line in (base / "calls.jsonl").read_text().splitlines()]
        probes = sum(call[0:3] == ["oc", "auth", "can-i"] for call in calls)
        print(results[min(probes - 1, len(results) - 1)])
        print(SENSITIVE_OUTPUT, file=sys.stderr)
        return settings.get("rbac_exit", 0)
    raise AssertionError(f"Unexpected mock cluster command: {arguments}")


class LeaseHealthRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)
        self.calls = []
        self.before = {}
        self.after = {}
        self.report = ""
        for name in ("bin", "profile", "artifacts", "tmp"):
            (self.base / name).mkdir()
        (self.base / "host-kubeconfig").touch()
        (self.base / "profile/ocm-token").write_text("fixture-token", encoding="utf-8")
        for command in ("oc", "ocm"):
            executable = self.base / "bin" / command
            executable.write_text(
                "#!/bin/bash\nexec " + shlex.quote(sys.executable) + " "
                + shlex.quote(str(Path(__file__).resolve())) + " --mock " + command + ' "$@"\n',
                encoding="utf-8")
            executable.chmod(0o755)
        script = STEP.read_text(encoding="utf-8")
        host_path = "/etc/rosa-cluster-lease-manager/kubeconfig"
        self.assertEqual(script.count(host_path), 1)
        (self.base / "health.sh").write_text(
            script.replace(host_path, str(self.base / "host-kubeconfig")), encoding="utf-8")

    def _run_step(self, statuses=("error",), **settings):
        inventory = {"items": [
            {"metadata": {"name": f"fixture-{index}", "labels": {PREFIX + "status": status},
                          "annotations": {PREFIX + "error-reason": "previous error",
                                          PREFIX + "error-at": "previous timestamp"}},
             "data": {"cluster-id": f"fixture-id-{index}"}}
            for index, status in enumerate(statuses)]}
        (self.base / "inventory.json").write_text(json.dumps(inventory), encoding="utf-8")
        (self.base / "settings.json").write_text(json.dumps(settings), encoding="utf-8")
        environment = {**os.environ, "PATH": str(self.base / "bin") + ":" + os.environ["PATH"],
                       "FIXTURE_DIR": str(self.base), "CLUSTER_PROFILE_DIR": str(self.base / "profile"),
                       "ARTIFACT_DIR": str(self.base / "artifacts"),
                       "TMPDIR": str(self.base / "tmp"), "STALE_LEASE_HOURS": "4",
                       "OCM_LOGIN_ENV": "staging"}
        result = subprocess.run(["bash", str(self.base / "health.sh")], env=environment,
                                capture_output=True, text=True, check=False, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(SENSITIVE_OUTPUT, result.stdout + result.stderr)
        self.assertEqual(list((self.base / "tmp").iterdir()), [])
        self.calls = [json.loads(line) for line in
                      (self.base / "calls.jsonl").read_text(encoding="utf-8").splitlines()]
        self.before = inventory
        self.after = json.loads((self.base / "inventory.json").read_text(encoding="utf-8"))
        self.report = (self.base / "artifacts/lease-health-report.txt").read_text(encoding="utf-8")

    def _assert_retained(self):
        self.assertEqual(self.after, self.before)
        self.assertFalse(any("patch" in call for call in self.calls))
        self.assertNotIn("RESTORED", self.report)
        self.assertIn("Summary: 0 healthy, 1 unhealthy", self.report)

    def _assert_credentials_skipped(self):
        self._assert_retained()
        host_argument = "--kubeconfig=" + str(self.base / "host-kubeconfig")
        self.assertFalse(any(call[0] == "oc" and call[1] != host_argument for call in self.calls))

    def test_verified_rbac_restores_error(self):
        self._run_step()
        metadata = self.after["items"][0]["metadata"]
        self.assertEqual(metadata["labels"][PREFIX + "status"], "available")
        self.assertEqual(metadata["annotations"][PREFIX + "error-reason"], "")
        self.assertEqual(metadata["annotations"][PREFIX + "error-at"], "")
        self.assertIn("RESTORED to available", self.report)
        self.assertIn("Summary: 1 healthy, 0 unhealthy", self.report)
        probes = [call for call in self.calls if call[:3] == ["oc", "auth", "can-i"]]
        packages = [call for call in self.calls if call[2:4] == ["get", "clusterpackage"]]
        self.assertEqual(len(probes), 1)
        self.assertEqual(len(packages), 1)
        self.assertIn(packages[0][1], probes[0])
        self.assertEqual(sum(call[0] == "ocm" and call[-1].endswith("/credentials")
                             for call in self.calls), 1)

    def test_explicit_denial_retains_error(self):
        self._run_step(rbac_result="no", rbac_exit=1)
        self._assert_retained()

    def test_denial_with_zero_exit_retains_error(self):
        self._run_step(rbac_result="no")
        self._assert_retained()

    def test_empty_probe_retains_error(self):
        self._run_step(rbac_result="")
        self._assert_retained()

    def test_unexpected_probe_retains_error(self):
        self._run_step(rbac_result="unknown")
        self._assert_retained()

    def test_extra_output_retains_error(self):
        self._run_step(rbac_result="yes\nwarning")
        self._assert_retained()

    def test_whitespace_padded_yes_retains_error(self):
        for output in (" yes", "yes "):
            with self.subTest(output=output):
                self._run_step(rbac_result=output)
                self._assert_retained()

    def test_probe_failure_retains_error(self):
        self._run_step(rbac_result="", rbac_exit=1)
        self._assert_retained()

    def test_yes_with_failed_command_retains_error(self):
        self._run_step(rbac_result="yes", rbac_exit=1)
        self._assert_retained()

    def test_credentials_failure_retains_error(self):
        self._run_step(credentials_exit=1)
        self._assert_credentials_skipped()

    def test_missing_credentials_retains_error(self):
        self._run_step(credentials="{}")
        self._assert_credentials_skipped()

    def test_null_credentials_retains_error(self):
        self._run_step(credentials='{"kubeconfig": null}')
        self._assert_credentials_skipped()

    def test_empty_credentials_retains_error(self):
        self._run_step(credentials='{"kubeconfig": ""}')
        self._assert_credentials_skipped()

    def test_malformed_credentials_retains_error(self):
        self._run_step(credentials="not json")
        self._assert_credentials_skipped()

    def test_clusterpackage_failure_retains_error(self):
        self._run_step(cp_available="False")
        self._assert_retained()
        self.assertFalse(any(call[:3] == ["oc", "auth", "can-i"] for call in self.calls))

    def test_ocm_not_ready_retains_error(self):
        self._run_step(ocm_status="installing")
        self._assert_retained()
        self.assertFalse(any(call[:3] == ["oc", "auth", "can-i"] for call in self.calls))

    def test_clusterpackage_list_failure_preserves_existing_recovery_policy(self):
        self._run_step(cp_unavailable=True)
        self.assertEqual(self.after["items"][0]["metadata"]["labels"][PREFIX + "status"],
                         "available")
        self.assertIn("RESTORED to available", self.report)

    def test_non_error_leases_preserve_existing_behavior(self):
        self._run_step(statuses=("available", "in-use", "provisioning"), rbac_result="no")
        self.assertEqual(self.after, self.before)
        self.assertFalse(any(call[:3] == ["oc", "auth", "can-i"] for call in self.calls))
        self.assertIn("Summary: 3 healthy, 0 unhealthy", self.report)

    def test_rbac_result_does_not_leak_between_clusters(self):
        self._run_step(statuses=("error", "error", "error"), rbac_results=["yes", "no", ""])
        self.assertEqual(self.after["items"][0]["metadata"]["labels"][PREFIX + "status"],
                         "available")
        self.assertEqual(self.after["items"][1:], self.before["items"][1:])
        self.assertEqual(self.report.count("RESTORED to available"), 1)
        self.assertIn("Summary: 1 healthy, 2 unhealthy", self.report)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
