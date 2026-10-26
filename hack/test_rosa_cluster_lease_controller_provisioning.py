#!/usr/bin/env python3
"""Offline controller fixtures: python3 hack/test_rosa_cluster_lease_controller_provisioning.py."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


STEP = (Path(__file__).resolve().parents[1] / "ci-operator/step-registry/rosa/cluster-lease"
        / "controller/rosa-cluster-lease-controller-commands.sh")
PREFIX = "rosa-cluster-lease/"
NAME = "fixture-cluster"
ENDPOINT = "/api/clusters_mgmt/v1/clusters/fixture-id"


def merge_patch(target, patch):
    for key, value in patch.items():
        if isinstance(value, dict):
            merge_patch(target.setdefault(key, {}), value)
        else:
            target[key] = value


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps([command, *arguments]) + "\n")
    case = json.loads((base / "case.json").read_text(encoding="utf-8"))
    if command == "ocm":
        if arguments in (["login", "--url", environment, "--token", "fixture-token"]
                         for environment in ("staging", "integration")):
            return 0
        if arguments == ["get", ENDPOINT]:
            print(case["response"], end="")
            return case["returncode"]
    if command == "oc" and arguments[0] == "--kubeconfig=" + str(base / "host-kubeconfig"):
        return mock_inventory_command(arguments[1:], base, case)
    raise AssertionError(f"Unexpected fixture command: {command} {arguments}")


def mock_inventory_command(arguments, base, case):
    inventory_path = base / "inventory.json"
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    if arguments == ["get", "configmap", "rosa-cluster-lease-config", "-n", "fixture", "-o", "json"]:
        print(json.dumps({"data": {"desired-clusters": f"- name: {NAME}\n"}}))
        return 0
    if arguments[:5] == ["get", "configmap", "-n", "fixture", "-l"] and arguments[-2:] == ["-o", "json"]:
        if arguments[5] == PREFIX + "managed=true":
            print(json.dumps(inventory))
            return 0
        if arguments[5] == PREFIX + "managed=true," + PREFIX + "status=error":
            print(json.dumps({"items": [item for item in inventory["items"]
                                       if item["metadata"]["labels"][PREFIX + "status"] == "error"]}))
            return 0
    if arguments[:8] == ["patch", "configmap", NAME, "-n", "fixture", "--type", "merge", "-p"] and len(arguments) == 9:
        if case["patch_failure"]:
            return 1
        merge_patch(inventory["items"][0], json.loads(arguments[8]))
    elif arguments == ["delete", "configmap", NAME, "-n", "fixture"]:
        if case["delete_failure"]:
            return 1
        inventory = {"items": []}
    else:
        raise AssertionError(f"Unexpected fixture inventory command: {arguments}")
    inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
    return 0


class ProvisioningControllerTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)
        for directory in ("bin", "artifacts", "profile", "tmp"):
            (self.base / directory).mkdir()
        (self.base / "host-kubeconfig").write_text("fixture", encoding="utf-8")
        (self.base / "profile/ocm-token").write_text("fixture-token", encoding="utf-8")
        self.script = self.base / STEP.name
        self.script.write_text(STEP.read_text(encoding="utf-8").replace(
            "/etc/rosa-cluster-lease-manager/kubeconfig", str(self.base / "host-kubeconfig")),
            encoding="utf-8")
        for command in ("oc", "ocm", "rosa", "aws", "gcloud"):
            executable = self.base / "bin" / command
            executable.write_text(
                f"#!/bin/bash\nexec {shlex.quote(sys.executable)} "
                f"{shlex.quote(str(Path(__file__).resolve()))} --mock {command} \"$@\"\n",
                encoding="utf-8")
            executable.chmod(0o755)
        self.inventory = {"items": [{
            "metadata": {"name": NAME, "labels": {
                PREFIX + "managed": "true", PREFIX + "status": "provisioning",
                PREFIX + "version": "4.21", PREFIX + "type": "classic-sts",
            }, "annotations": {PREFIX + "registered-at": "2026-01-01T00:00:00Z",
                               PREFIX + "holder": "", "fixture": "preserve"}},
            "data": {"cluster-id": "fixture-id", "cluster-name": NAME,
                     "ocm-env": "integration", "version": "4.21.1", "api-url": "old", "region": "fixture"},
        }]}
        self.response = {"id": "fixture-id", "status": {"state": "ready"},
                         "api": {"url": 'https://api.fixture.invalid/"quoted"'}, "openshift_version": "4.22.7"}

    def run_controller(self, state="ready", **options):
        self.response["status"] = {"state": state}
        inventory_path = self.base / "inventory.json"
        inventory_path.write_text(json.dumps(self.inventory), encoding="utf-8")
        case = {"response": json.dumps(self.response), "returncode": 0,
                "patch_failure": False, "delete_failure": False}
        dry_run = options.pop("dry_run", False)
        case.update(options)
        (self.base / "case.json").write_text(json.dumps(case), encoding="utf-8")
        result = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.base / "bin") + os.pathsep + os.defpath,
            "HOME": str(self.base), "FIXTURE_DIR": str(self.base),
            "ARTIFACT_DIR": str(self.base / "artifacts"), "TMPDIR": str(self.base / "tmp"),
            "CLUSTER_PROFILE_DIR": str(self.base / "profile"), "LEASE_NAMESPACE": "fixture",
            "OCM_LOGIN_ENV": "staging", "DRY_RUN": str(dry_run).lower(),
            "MAX_CLUSTER_AGE_HOURS": "0", "ERROR_REPLACE_HOURS": "1",
        }, capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = (self.base / "artifacts/controller-report.txt").read_text(encoding="utf-8")
        self.assertIn(report, result.stdout)
        calls = [json.loads(line) for line in
                 (self.base / "calls.jsonl").read_text(encoding="utf-8").splitlines()]
        expected_ocm = [["ocm", "login", "--url", "staging", "--token", "fixture-token"]]
        if self.inventory["items"][0]["data"].get("ocm-env", "staging") == "integration":
            expected_ocm.append(["ocm", "login", "--url", "integration", "--token", "fixture-token"])
        expected_ocm.append(["ocm", "get", ENDPOINT])
        self.assertEqual([call for call in calls if call[0] == "ocm"], expected_ocm)
        self.assertTrue(all(call[0] in ("oc", "ocm") for call in calls))
        self.assertEqual(list((self.base / "tmp").iterdir()), [])
        mutations = [call[2:] for call in calls if call[0] == "oc" and call[2] != "get"]
        return json.loads(inventory_path.read_text(encoding="utf-8")), report, mutations, result.stderr

    def test_ready_updates_metadata_without_reregistering(self):
        inventory, report, mutations, _ = self.run_controller()
        expected = json.loads(json.dumps(self.inventory))
        expected["items"][0]["metadata"]["labels"].update({PREFIX + "status": "available", PREFIX + "version": "4.22"})
        expected["items"][0]["data"].update({"api-url": self.response["api"]["url"], "version": "4.22.7"})
        self.assertEqual(inventory, expected)
        self.assertEqual(len(mutations), 1)
        self.assertIn("PROVISIONED: " + NAME + " (available)", report)
        self.assertIn("Summary: 1 healthy, 0 unhealthy", report)

    def test_terminal_states_stamp_error_and_enter_delayed_replacement(self):
        for state in ("error", "uninstalling"):
            with self.subTest(state=state):
                self.setUp()
                before = datetime.now(timezone.utc).replace(microsecond=0)
                inventory, report, mutations, stderr = self.run_controller(state)
                current = inventory["items"][0]
                self.assertEqual(current["metadata"]["labels"][PREFIX + "status"], "error")
                annotations = current["metadata"]["annotations"]
                self.assertEqual(annotations[PREFIX + "error-reason"], "OCM status: " + state)
                error_at = datetime.strptime(annotations[PREFIX + "error-at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                self.assertLessEqual(before, error_at)
                self.assertLessEqual(error_at, datetime.now(timezone.utc))
                self.assertEqual(current["data"], self.inventory["items"][0]["data"])
                self.assertEqual(annotations["fixture"], "preserve")
                self.assertEqual(len(mutations), 1)
                self.assertIn("Summary: 0 healthy, 1 unhealthy", report)
                self.assertIn("threshold is 60m. Waiting.", stderr)

    def assert_unchanged(self, state="ready", **options):
        inventory, report, mutations, _ = self.run_controller(state, **options)
        self.assertEqual(inventory, self.inventory)
        self.assertEqual(mutations, [])
        return report

    def test_in_progress_states_remain_provisioning(self):
        for state in ("pending", "installing", "waiting"):
            with self.subTest(state=state):
                self.setUp()
                self.assertIn("PROVISIONING: " + NAME + " (OCM: " + state + ")", self.assert_unchanged(state))

    def test_unknown_or_missing_state_remains_provisioning(self):
        for response in ({"id": "fixture-id"}, {"id": "fixture-id", "status": {"state": "unexpected"}}):
            with self.subTest(response=response):
                self.setUp()
                report = self.assert_unchanged(response=json.dumps(response))
                self.assertIn("unexpected OCM state", report)
                self.assertIn("Summary: 0 healthy, 0 unhealthy", report)

    def test_unreachable_responses_preserve_inventory(self):
        for response, returncode in (("", 0), ("", 1), ("connection refused", 1),
                                     ("not json", 0), ("{}", 0), (json.dumps(self.response), 1)):
            with self.subTest(response=response, returncode=returncode):
                self.setUp()
                report = self.assert_unchanged(response=response, returncode=returncode)
                self.assertIn("SKIPPED: " + NAME + " (OCM unreachable)", report)

    def test_ready_with_incomplete_metadata_retries(self):
        for key in ("api", "openshift_version"):
            for value in (None, ""):
                with self.subTest(key=key, value=value):
                    self.setUp()
                    self.response[key] = {"url": value} if key == "api" else value
                    self.assertIn("ready, incomplete cluster data", self.assert_unchanged())

    def test_dry_run_never_mutates(self):
        for state in ("ready", "error", "uninstalling", "pending", "installing", "waiting"):
            with self.subTest(state=state):
                self.setUp()
                report = self.assert_unchanged(state, dry_run=True)
                if state in ("ready", "error", "uninstalling"):
                    self.assertIn("DRY RUN:", report)

    def test_patch_failures_preserve_provisioning_and_report_failure(self):
        for state in ("ready", "error", "uninstalling"):
            with self.subTest(state=state):
                self.setUp()
                inventory, report, mutations, stderr = self.run_controller(state, patch_failure=True)
                self.assertEqual(inventory, self.inventory)
                self.assertEqual(len(mutations), 1)
                self.assertIn("patch failed", report)
                self.assertIn("Failed to mark " + NAME, stderr)
                self.assertNotIn("PROVISIONED:", report)

    def test_not_found_removes_only_stale_inventory(self):
        for returncode in (0, 1):
            with self.subTest(returncode=returncode):
                self.setUp()
                inventory, report, mutations, _ = self.run_controller(response='{"id":"404"}', returncode=returncode)
                self.assertEqual(inventory, {"items": []})
                self.assertEqual(mutations, [["delete", "configmap", NAME, "-n", "fixture"]])
                self.assertIn("removed, will reprovision next run", report)

    def test_not_found_dry_run_preserves_inventory(self):
        report = self.assert_unchanged(response='{"id":"404"}', returncode=1, dry_run=True)
        self.assertIn("stale provisioning, would remove", report)

    def test_not_found_delete_failure_preserves_inventory(self):
        inventory, report, mutations, _ = self.run_controller(response='{"id":"404"}', returncode=1, delete_failure=True)
        self.assertEqual(inventory, self.inventory)
        self.assertEqual(mutations, [["delete", "configmap", NAME, "-n", "fixture"]])
        self.assertIn("delete failed", report)

    def test_missing_ocm_environment_defaults_to_staging(self):
        del self.inventory["items"][0]["data"]["ocm-env"]
        self.assert_unchanged("installing")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
