#!/usr/bin/env python3
"""Offline report fixtures: python3 hack/test_rosa_cluster_lease_health_provisioning.py."""

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
        / "health/rosa-cluster-lease-health-commands.sh")
PREFIX = "rosa-cluster-lease/"


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps([command, *arguments]) + "\n")
    if command == "oc":
        if arguments == ["--kubeconfig=" + str(base / "host-kubeconfig"), "get", "configmap",
                         "-n", "fixture", "-l", PREFIX + "managed=true", "-o", "json"]:
            print((base / "inventory.json").read_text(encoding="utf-8"))
            return 0
    elif command == "ocm":
        if arguments == ["login", "--url", "staging", "--token", "fixture-token"]:
            return 0
        if arguments == ["get", "/api/clusters_mgmt/v1/clusters/fixture-available"]:
            print(json.dumps({"status": {"state": "ready"}}))
            return 0
        if arguments == ["get", "/api/clusters_mgmt/v1/clusters/fixture-available/credentials"]:
            return 1
        if arguments == ["get", "/api/clusters_mgmt/v1/clusters/fixture-error"]:
            print(json.dumps({"status": {"state": "error"}}))
            return 0
    raise AssertionError(f"Unexpected fixture command: {command} {arguments}")


class ProvisioningReportTests(unittest.TestCase):
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
        for command in ("oc", "ocm"):
            executable = self.base / "bin" / command
            executable.write_text(
                f"#!/bin/bash\nexec {shlex.quote(sys.executable)} "
                f"{shlex.quote(str(Path(__file__).resolve()))} --mock {command} \"$@\"\n",
                encoding="utf-8")
            executable.chmod(0o755)

    def run_inventory(self, statuses, summary):
        inventory = {"items": [{
            "metadata": {"name": f"fixture-{index}", "labels": {PREFIX + "status": status}},
            "data": {"cluster-id": f"fixture-{status}",
                     "ocm-env": "integration" if status == "provisioning" else "staging"},
        } for index, status in enumerate(statuses)]}
        inventory_path = self.base / "inventory.json"
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
        result = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.base / "bin") + os.pathsep + os.defpath,
            "HOME": str(self.base), "FIXTURE_DIR": str(self.base),
            "ARTIFACT_DIR": str(self.base / "artifacts"), "TMPDIR": str(self.base / "tmp"),
            "CLUSTER_PROFILE_DIR": str(self.base / "profile"), "LEASE_NAMESPACE": "fixture",
            "OCM_LOGIN_ENV": "staging",
        }, capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.base / "artifacts/lease-health-report.txt").read_text(encoding="utf-8")
        self.assertEqual([line for line in report.splitlines() if line.startswith("Summary:")],
                         ["Summary: " + summary])
        self.assertIn(report, result.stdout)
        self.assertIn("Lease health check complete: " + summary.replace(
            " recovered", " stale leases recovered"), result.stderr)
        self.assertEqual(report.count("Provisioning (skipped)"), statuses.count("provisioning"))
        self.assertEqual(json.loads(inventory_path.read_text(encoding="utf-8")), inventory)
        self.assertEqual(list((self.base / "tmp").iterdir()), [])
        calls = [json.loads(line) for line in
                 (self.base / "calls.jsonl").read_text(encoding="utf-8").splitlines()]
        expected_ocm = [["ocm", "login", "--url", "staging", "--token", "fixture-token"]]
        for status in statuses:
            if status in ("available", "error"):
                endpoint = "/api/clusters_mgmt/v1/clusters/fixture-" + status
                expected_ocm.append(["ocm", "get", endpoint])
                if status == "available":
                    expected_ocm.append(["ocm", "get", endpoint + "/credentials"])
        self.assertEqual([call for call in calls if call[0] == "ocm"], expected_ocm)
        self.assertEqual(len([call for call in calls if call[0] == "oc"]), 1)

    def test_provisioning_only(self):
        self.run_inventory(("provisioning", "provisioning"),
                           "0 healthy, 0 unhealthy, 0 recovered, 2 provisioning")

    def test_mixed_inventory(self):
        self.run_inventory(("provisioning", "available", "in-use", "error", "provisioning"),
                           "2 healthy, 1 unhealthy, 0 recovered, 2 provisioning")

    def test_empty_inventory(self):
        self.run_inventory((), "0 healthy, 0 unhealthy, 0 recovered, 0 provisioning")

    def test_without_provisioning(self):
        self.run_inventory(("available", "in-use", "error"),
                           "2 healthy, 1 unhealthy, 0 recovered, 0 provisioning")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
