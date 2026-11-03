#!/usr/bin/env python3
"""Offline execution of the delivered collector, with no network or credentials."""

import datetime
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

import test_rosa_ocm_fvt_artifacts as producer


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ("ci-operator/step-registry/rosa/e2e/gather-cluster-diagnostics/"
                 "rosa-e2e-gather-cluster-diagnostics-commands.sh")
CLUSTER = "a" * 32
SECRET = "FIXTURE_SECRET_MUST_NOT_APPEAR"


def mock_curl(base, case, arguments):
    if case == "download-failure":
        print(SECRET, file=sys.stderr)
        return 1
    destination = Path(arguments[arguments.index("-o") + 1])
    if destination.name == "ocm":
        shutil.copyfile(base / "bin/ocm", destination)
        if case == "missing-tool":
            destination.write_text("#!/nonexistent-fixture-interpreter\n", encoding="utf-8")
            (base / "bin/ocm").unlink()
    else:
        data = (base / "bin/ocm-backplane").read_bytes()
        with tarfile.open(destination, "w:gz") as archive:
            entry = tarfile.TarInfo("ocm-backplane")
            entry.size = len(data)
            entry.mode = 0o700
            if case == "archive-symlink":
                entry.type = tarfile.SYMTYPE
                entry.linkname = str(base / "outside")
                entry.size = 0
                archive.addfile(entry)
            else:
                archive.addfile(entry, io.BytesIO(data))
    return 0


def mock_ocm(base, case, arguments):
    if arguments[0] == "login":
        if case == "timeout":
            time.sleep(25)
        print(SECRET)
        return int(case == "login-failure")
    path = arguments[1]
    if case == "api-failure":
        print(SECRET, file=sys.stderr)
        return 1
    if case == "oversized":
        print("x" * (2 * 1024 * 1024))
        return 0
    if case == "invalid-json":
        print(SECRET)
        return 0
    if "?" in path:
        manifest = json.loads((base / "shared/ocm-fvt-diagnostic-identity.json").read_text())
        created = manifest["started"] if case != "old-match" else manifest["started"] - 1
        if case == "fractional-finish":
            created = int(manifest["finished"]) + 0.5
        cluster = {"id": CLUSTER, "name": "fixture-run-name", "creation_timestamp":
                   datetime.datetime.fromtimestamp(created, datetime.timezone.utc).isoformat()}
        if case == "replacement-cluster":
            cluster["id"] = "b" * 32
        print(json.dumps({"total": 2 if case == "ambiguous-match" else 1, "items": [cluster]}))
    elif path.endswith("/resources/live"):
        print(json.dumps({"cluster_id": CLUSTER, "resources": {
            "gcp-observation": json.dumps({"kind": "ProjectClaim", "spec": {"projectReferenceCRLink": {
                "name": SECRET, "namespace": SECRET}},
                "status": {"state": "Error", "message": SECRET,
                           "conditions": [{"type": "Error", "status": "True", "reason": "ReconcileError",
                                           "message": SECRET}]}}),
            "reference": json.dumps({"kind": "ProjectReference", "spec": {"projectClaimCRLink": {"name": "", "namespace": ""}},
                                      "status": {"state": "Verification"}}),
            SECRET: json.dumps({"kind": "Secret", "data": {"token": SECRET}})}}))
    elif path.endswith("/credentials"):
        if case == "missing-access":
            return 1
        print(json.dumps({"kubeconfig": "apiVersion: v1\nkind: Config\n"}))
    else:
        print(json.dumps({"id": CLUSTER, "state": "error" if case == "terminal" else "pending",
                          "provision_status": "PendingProject", "message": SECRET}))
    return 0


def mock(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    with (base / "calls").open("a", encoding="utf-8") as calls:
        calls.write(command + " " + ("login" if arguments[:1] == ["login"] else " ".join(arguments)) + "\n")
    if command == "curl":
        return mock_curl(base, case, arguments)
    if command == "ocm":
        return mock_ocm(base, case, arguments)
    if command == "ocm-backplane":
        return int(case in ("missing-access", "credential-fallback"))
    if command == "tar":
        if case == "tar-timeout":
            with subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"]) as descendant:
                (base / "descendant-pid").write_text(str(descendant.pid))
                time.sleep(25)
            return 0
        os.execv("/usr/bin/tar", ["tar", *arguments])
    if command == "oc":
        if "logs" in arguments:
            print("error panic timeout " + SECRET)
        elif "events" in arguments:
            print(json.dumps({"items": [{"type": "Warning", "message": SECRET}]}))
        else:
            print(json.dumps({"items": [{"metadata": {"name": "fixture-pod"}, "status": {
                "phase": "Pending", "message": SECRET, "conditions": [{"type": "Ready", "status": "False"}]}}]}))
        return 0
    if command == "podman":
        result = producer.mock_command(command, arguments)
        if arguments[0] == "run":
            recording = base / "artifacts/ocm-fvt-results/test-result-fixture/cluster.ini"
            recording.write_text("[Cluster]\nName=fixture-run-name\nID=" + CLUSTER +
                                 "\nState=pending\n[OtherResource]\nID=not-a-cluster\n")
            if case == "multi-cluster":
                second = recording.parent.parent / "another-profile"
                second.mkdir()
                (second / "cluster.ini").write_text("Name=another-run-name\nID=" + "b" * 32 + "\n")
        return result
    raise AssertionError("Unexpected fixture command")


class CollectorTests(unittest.TestCase):
    def run_fixture(self, case="normal", ids=CLUSTER, manifest=False, *, tracing=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ("bin", "shared", "artifacts", "credentials", "tmp"):
                (base / name).mkdir()
            for command in ("curl", "ocm", "ocm-backplane", "oc", "tar"):
                executable = base / "bin" / command
                executable.write_text(f'#!{sys.executable}\nimport sys\nsys.path.insert(0, {str(ROOT / "hack")!r})\n'
                                      f'import test_rosa_gather_diagnostics as fixtures\n'
                                      f'sys.exit(fixtures.mock({command!r}, sys.argv[1:]))\n')
                executable.chmod(0o700)
            if ids is not None:
                (base / "shared/cluster-id").write_text(ids)
            if manifest:
                data = {"run": "1", "job": "fixture", "names": ["fixture-run-name"], "ids": [CLUSTER], "outcome": "ok",
                        "started": int(time.time()) - 5, "finished": int(time.time())}
                if isinstance(manifest, dict):
                    data = dict(manifest)
                if case == "name-only":
                    data["ids"] = []
                if case == "unscoped":
                    data["run"] = "different-run"
                if case == "ambiguous-names":
                    data["names"].append("another-name")
                if case == "wrong-job":
                    data["job"] = "different-job"
                if case == "conflicting-id":
                    data["ids"] = ["b" * 32]
                if case == "malformed-recorded-id":
                    data["ids"] = ["../../credentials"]
                if case == "fractional-finish":
                    data["finished"] = int(time.time()) - 1 + 0.75
                (base / "shared/ocm-fvt-diagnostic-identity.json").write_text(json.dumps(data))
                if case == "malformed-manifest":
                    (base / "shared/ocm-fvt-diagnostic-identity.json").write_text("{invalid-json")
            if case != "missing-token":
                (base / "credentials/ocm_token").write_text(SECRET)
            if case == "symlink-id":
                (base / "shared/cluster-id").unlink()
                (base / "shared/cluster-id").symlink_to(base / "credentials/ocm_token")
            delivered = base / "delivered.sh"
            delivered.write_text(SCRIPT.read_text().replace("/usr/local/cs-qe-credentials", str(base / "credentials")))
            environment = {"PATH": str(base / "bin") + os.pathsep + os.defpath,
                           "ARTIFACT_DIR": str(base / "artifacts"), "SHARED_DIR": str(base / "shared"),
                           "FIXTURE_DIR": str(base), "FIXTURE_CASE": case, "TMPDIR": str(base / "tmp"),
                           "BUILD_ID": "1", "JOB_NAME": "fixture"}
            if case == "environment-alias":
                environment["GATHER_OCM_ENV"] = "stage"
            if case == "budget-exhausted":
                (base / "sitecustomize.py").write_text(
                    "import sys, time\nif sys.argv == ['-']:\n"
                    "    ticks = iter([0, 451])\n    time.monotonic = lambda: next(ticks, 451)\n")
                environment["PYTHONPATH"] = str(base)
            result = subprocess.run(["bash", *(["-x"] if tracing else []), str(delivered)],
                                    env=environment, capture_output=True, text=True, timeout=40, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            artifacts = {path.name: json.loads(path.read_text()) for path in
                         (base / "artifacts/cluster-diagnostics").iterdir()}
            self.assertNotIn(SECRET, result.stdout + result.stderr + json.dumps(artifacts))
            self.assertNotIn(CLUSTER, json.dumps(artifacts))
            self.assertLess(len(json.dumps(artifacts)), 32768)
            self.assertEqual(list((base / "tmp").iterdir()), [], "Private session files must be removed")
            calls = (base / "calls").read_text() if (base / "calls").exists() else ""
            self.assertLessEqual(len(calls.splitlines()), 30)
            if case == "tar-timeout":
                descendant = int((base / "descendant-pid").read_text())
                process_status = Path("/proc") / str(descendant) / "stat"
                live = process_status.exists() and process_status.read_text().split()[2] != "Z"
                try:
                    self.assertFalse(live, "Timed-out extraction must stop its decompressor descendant")
                finally:
                    if live:
                        os.kill(descendant, signal.SIGKILL)
            return artifacts, calls

    def test_empty_shared_has_explicit_outcome_without_access(self):
        artifacts, calls = self.run_fixture(ids=None)
        self.assertIn("missing_identity", artifacts["collection-outcome.json"]["reason"])
        self.assertEqual(calls, "")

    def test_id_rejection(self):
        for ids, reason in (("../../credentials", "malformed_identity"),
                            (CLUSTER + "\n" + "b" * 32, "ambiguous_identity")):
            with self.subTest(reason=reason):
                artifacts, calls = self.run_fixture(ids=ids)
                self.assertEqual(artifacts["collection-outcome.json"]["reason"], reason)
                self.assertNotIn("ocm-backplane", calls)

    def test_name_recovery_is_run_bound_and_unique(self):
        artifacts, calls = self.run_fixture(ids=None, manifest=True)
        self.assertEqual(artifacts["collection-outcome.json"]["identity"], "unique_run_name")
        self.assertEqual(calls.count("clusters?"), 1)
        for case in ("unscoped", "old-match", "ambiguous-match", "ambiguous-names", "name-only",
                     "replacement-cluster", "wrong-job"):
            with self.subTest(case=case):
                artifacts, calls = self.run_fixture(case, ids=None, manifest=True)
                self.assertEqual(artifacts["collection-outcome.json"]["collector"], "incomplete")
                self.assertNotIn("/resources/live", calls)

    def test_manifest_ambiguity_and_conflicts_override_legacy_id(self):
        for case in ("ambiguous-names", "conflicting-id", "malformed-recorded-id", "malformed-manifest"):
            artifacts, calls = self.run_fixture(case, manifest=True)
            self.assertEqual(artifacts["collection-outcome.json"]["collector"], "incomplete")
            self.assertNotIn("/resources/live", calls)

    def test_fractional_creation_in_final_run_second_is_accepted(self):
        artifacts, _ = self.run_fixture("fractional-finish", ids=None, manifest=True)
        self.assertEqual(artifacts["collection-outcome.json"]["identity"], "unique_run_name")

    def test_tool_archive_cannot_supply_symlink_executable(self):
        artifacts, calls = self.run_fixture("archive-symlink")
        self.assertEqual(artifacts["collection-outcome.json"]["reason"], "invalid_tool_archive")
        self.assertIn("preinstall-resources.json", artifacts)
        self.assertNotIn("ocm-backplane login", calls)

    def test_extraction_timeout_stops_decompressor_and_preserves_fallback(self):
        artifacts, calls = self.run_fixture("tar-timeout")
        self.assertEqual(artifacts["collection-outcome.json"]["backplane_tool"], "timeout")
        self.assertEqual(artifacts["collection-outcome.json"]["credentials_api"], "ok")
        self.assertIn("preinstall-resources.json", artifacts)
        self.assertNotIn("ocm-backplane login", calls)

    def test_symlink_identity_is_not_read(self):
        artifacts, calls = self.run_fixture("symlink-id")
        self.assertEqual(artifacts["collection-outcome.json"]["reason"], "invalid_identity_file")
        self.assertNotIn("/resources/live", calls)

    def test_budget_exhaustion_launches_no_commands(self):
        artifacts, calls = self.run_fixture("budget-exhausted")
        self.assertEqual(artifacts["collection-outcome.json"]["reason"], "ocm_install_budget_exhausted")
        self.assertEqual(calls, "")

    def test_preinstall_survives_no_guest_access(self):
        artifacts, calls = self.run_fixture("missing-access")
        self.assertLess(calls.index("/resources/live"), calls.index("ocm-backplane login"))
        self.assertEqual(artifacts["collection-outcome.json"]["guest"], "access_unavailable")
        self.assertEqual(artifacts["preinstall-resources.json"]["resources"][0]["status"]["state"], "Error")
        self.assertTrue(artifacts["preinstall-resources.json"]["resources"][0]["reference_present"])
        self.assertTrue(artifacts["preinstall-resources.json"]["resources"][0]["status"]["conditions"][0]["reconcile_error"])
        self.assertEqual(artifacts["preinstall-resources.json"]["resources"][1]["kind"], "ProjectReference")
        self.assertFalse(artifacts["preinstall-resources.json"]["resources"][1]["reference_present"])

    def test_terminal_error_is_observed_not_reinterpreted_as_test_exit(self):
        artifacts, _ = self.run_fixture("terminal")
        self.assertEqual(artifacts["cluster.json"]["state"], "error")
        self.assertIn("unsupported", artifacts["collection-outcome.json"]["operator_logs"])

    def test_existing_guest_and_credentials_fallback(self):
        for case in ("normal", "credential-fallback", "environment-alias"):
            with self.subTest(case=case):
                artifacts, calls = self.run_fixture(case, tracing=True)
                self.assertEqual(artifacts["collection-outcome.json"]["collector"], "complete")
                self.assertEqual(artifacts["oauth-apiserver-pods-0.json"]["signals"]["panic"], 1)
                self.assertEqual(artifacts["openshift-etcd-events.json"]["types"]["Warning"], 1)
                self.assertIn("oc --request-timeout=15s", calls)
                if case == "credential-fallback":
                    self.assertEqual(artifacts["collection-outcome.json"]["backplane_access"], "command_failed")
                    self.assertEqual(artifacts["collection-outcome.json"]["credentials_api"], "ok")

    def test_api_and_tool_failures_are_safe_and_explicit(self):
        for case in ("api-failure", "invalid-json", "oversized", "download-failure", "login-failure",
                     "missing-tool", "missing-token", "timeout"):
            with self.subTest(case=case):
                artifacts, _ = self.run_fixture(case)
                outcome = artifacts["collection-outcome.json"]
                self.assertTrue(outcome["collector"] == "incomplete" or
                                artifacts["cluster.json"]["outcome"] != "ok")


class ProducerHandoffTests(producer.ArtifactFixture):
    def mock_producer(self):
        executable = self.bin / "podman"
        executable.write_text(f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" --mock podman "$@"\n')

    def test_actual_failed_producer_preserves_name_handoff_and_cleanup(self):
        self.mock_producer()
        self.run_step(exit_code=42)
        manifest = json.loads((self.shared / "ocm-fvt-diagnostic-identity.json").read_text())
        self.assertEqual(manifest["names"], ["fixture-run-name"])
        self.assertEqual(manifest["run"], "1")
        self.assertIsInstance(manifest["finished"], float)
        self.assertLessEqual(manifest["started"], manifest["finished"])
        collector = CollectorTests()
        artifacts, _ = collector.run_fixture(ids=None, manifest=manifest)
        self.assertEqual(artifacts["collection-outcome.json"]["identity"], "unique_run_name")
        for case in ("unscoped", "wrong-job"):
            artifacts, calls = collector.run_fixture(case, ids=None, manifest=manifest)
            self.assertEqual(artifacts["collection-outcome.json"]["reason"], "unscoped_identity")
            self.assertNotIn("/resources/live", calls)

    def test_actual_multi_profile_handoff_rejects_first_legacy_id(self):
        self.mock_producer()
        self.run_step("multi-cluster", exit_code=42)
        manifest = json.loads((self.shared / "ocm-fvt-diagnostic-identity.json").read_text())
        self.assertEqual(len(manifest["ids"]), 2)
        artifacts, calls = CollectorTests().run_fixture(manifest=manifest)
        self.assertEqual(artifacts["collection-outcome.json"]["collector"], "incomplete")
        self.assertNotIn("/resources/live", calls)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--mock"]:
        sys.exit(mock(sys.argv[2], sys.argv[3:]))
    unittest.main()
