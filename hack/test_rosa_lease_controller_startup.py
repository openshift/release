#!/usr/bin/env python3
"""Offline startup fixtures: python3 hack/test_rosa_lease_controller_startup.py.

The delivered command script of the rosa-cluster-lease-controller ref is run as
delivered, with stub CLIs on PATH and with the lease host kubeconfig path
pointed at a fixture file, so no cloud, OCM or Kubernetes endpoint is reached.
The fixtures cover the window before reconciliation starts: a controller that
cannot authenticate must still leave a sanitized log line and a partial report
behind, must keep the exit status and the retry schedule of the login helper,
must not disclose credentials or raw OCM output through either stream or
through the artifact directory, and must stop before reconciling when it
cannot report on the clusters it would act on.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/rosa/cluster-lease/controller"
REF = STEP / "rosa-cluster-lease-controller-ref.yaml"
HOST_KUBECONFIG = "/etc/rosa-cluster-lease-manager/kubeconfig"
CANARY = "FIXTURE_SECRET_DO_NOT_PRINT"
RAW_ERROR = "FIXTURE_RAW_OCM_ERROR_DO_NOT_PRINT"
LOGIN_EXIT = 70
STUBS = ("ocm", "oc", "rosa", "aws", "sleep")
CASES = ("login-ok", "login-failure", "login-retry-ok")
CREDENTIAL_FILES = {
    "ocm-token": ("ocm-token",),
    "sso-client": ("sso-client-id", "sso-client-secret"),
    "none": (),
}
FORBIDDEN = (CANARY, RAW_ERROR, "--token", "--client-id", "--client-secret")


def mock_command(command, arguments):
    """Stand in for one CLI the controller invokes, recording every call."""
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    if case not in CASES:
        raise AssertionError("Unknown fixture case")
    with (base / "calls").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps([command, *arguments]) + "\n")
    if command == "sleep":
        return 0
    if command == "ocm":
        if arguments[0] != "login":
            raise AssertionError("Unexpected OCM operation")
        # A real failure prints a description of the rejected request; the
        # controller must keep that payload out of its log and artifacts.
        print(RAW_ERROR)
        print(RAW_ERROR, file=sys.stderr)
        attempt = sum(1 for line in (base / "calls").read_text(encoding="utf-8").splitlines()
                      if json.loads(line)[:2] == ["ocm", "login"])
        if case == "login-ok" or (case == "login-retry-ok" and attempt > 1):
            return 0
        return LOGIN_EXIT
    if command == "oc":
        # No lease ConfigMap exists, which ends the run at the first
        # reconcile phase without mutating anything.
        return 1
    raise AssertionError("Unexpected fixture command")


class StartupDiagnosticsTests(unittest.TestCase):
    """Run the delivered controller command around its first OCM login."""

    def setUp(self):
        # Declared here, assigned per run so each run is fully isolated.
        self.base = None
        self.binaries = None
        self.profile = None
        self.artifacts = None
        self.script = None

    def prepare(self, artifacts):
        """Create an isolated fixture: stub CLIs, a profile and the script."""
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(self.remove, self.base)
        self.binaries = self.base / "bin"
        self.binaries.mkdir()
        for command in STUBS:
            stub = self.binaries / command
            stub.write_text(
                f'#!/bin/bash\nexec "{sys.executable}" -I "{Path(__file__).resolve()}" '
                f'--mock {command} "$@"\n', encoding="utf-8")
            stub.chmod(0o755)
        self.profile = self.base / "profile"
        self.profile.mkdir()
        kubeconfig = self.base / "kubeconfig"
        kubeconfig.touch()
        # "blocked" is a path under a regular file, so the destination is
        # unusable whichever user runs the fixture, unlike a mode-stripped
        # directory, which uid 0 may still write to.
        self.artifacts = {
            "absent": self.base / "missing/artifacts",
            "blocked": kubeconfig / "artifacts",
        }.get(artifacts, self.base / "artifacts")
        if artifacts in ("normal", "unwritable", "unset"):
            self.artifacts.mkdir()
        if artifacts == "unwritable":
            self.artifacts.chmod(0o500)
        ref = REF.read_text(encoding="utf-8")
        filename = next(line.split(": ", 1)[1] for line in ref.splitlines()
                        if line.startswith("  commands: "))
        body = (STEP / filename).read_text(encoding="utf-8")
        self.assertIn(HOST_KUBECONFIG, body)
        self.script = self.base / filename
        self.script.write_text(body.replace(HOST_KUBECONFIG, str(kubeconfig)), encoding="utf-8")

    @staticmethod
    def remove(base):
        artifacts = base / "artifacts"
        if artifacts.is_dir():
            artifacts.chmod(0o700)
        shutil.rmtree(base)

    def run_controller(self, case="login-failure", credentials="ocm-token", artifacts="normal"):
        """Run the controller once and return its result, report and calls."""
        self.prepare(artifacts)
        for name in CREDENTIAL_FILES[credentials]:
            (self.profile / name).write_text(CANARY, encoding="utf-8")
        environment = {
            "PATH": str(self.binaries) + os.pathsep + os.defpath,
            "HOME": str(self.base),
            "CLUSTER_PROFILE_DIR": str(self.profile),
            "FIXTURE_DIR": str(self.base),
            "FIXTURE_CASE": case,
        }
        if artifacts != "unset":
            environment["ARTIFACT_DIR"] = str(self.artifacts)
        result = subprocess.run(["bash", str(self.script)], env=environment, check=False,
                                capture_output=True, text=True, timeout=120)
        report = self.artifacts / "controller-report.txt"
        contents = report.read_text(encoding="utf-8") if report.is_file() else None
        calls = [json.loads(line) for line in
                 (self.base / "calls").read_text(encoding="utf-8").splitlines()] \
            if (self.base / "calls").is_file() else []
        self.assert_sanitized(result, contents)
        return result, contents, calls

    def assert_sanitized(self, result, report):
        """No credential, raw OCM output or command argument may be disclosed."""
        published = [result.stdout, result.stderr, report or ""]
        for path in sorted(self.artifacts.rglob("*")) if self.artifacts.is_dir() else []:
            if path.is_file():
                published.append(path.read_text(encoding="utf-8", errors="replace"))
        for text in published:
            for secret in FORBIDDEN:
                self.assertNotIn(secret, text)

    def assert_phase(self, result, report, line):
        """A phase outcome reaches both the build log and the report."""
        self.assertIn(line, result.stderr)
        self.assertIsNotNone(report, "a partial report must exist")
        self.assertIn(line, report)

    @staticmethod
    def commands(calls, name):
        return [call for call in calls if call[0] == name]

    def test_initial_authentication_failure_is_diagnosed(self):
        """Both credential modes leave a sanitized log line and a partial report."""
        for credentials in ("ocm-token", "sso-client"):
            with self.subTest(credentials=credentials):
                result, report, calls = self.run_controller(credentials=credentials)
                self.assertEqual(result.returncode, LOGIN_EXIT, result.stderr)
                started = "PHASE: startup started credentials=unknown attempts=0 exit=0"
                failed = ("PHASE: authentication failed "
                          f"credentials={credentials} attempts=3 exit={LOGIN_EXIT}")
                self.assert_phase(result, report, started)
                self.assert_phase(result, report, failed)
                header, *body = report.splitlines()
                self.assertTrue(header.startswith("Lease Controller Report - "), header)
                self.assertEqual(body, ["======================================", started, failed])
                self.assertEqual(len(self.commands(calls, "ocm")), 3)
                self.assertEqual(self.commands(calls, "sleep"), [["sleep", "10"]] * 2)
                self.assertEqual([call[0] for call in calls if call[0] not in ("ocm", "sleep")], [])

    def test_missing_credentials_are_distinguished(self):
        """Without any credential the controller reports that, and attempts no login."""
        result, report, calls = self.run_controller(credentials="none")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_phase(result, report,
                          "PHASE: authentication no-credentials credentials=none attempts=0 exit=1")
        self.assertEqual(calls, [])

    def test_successful_authentication_continues(self):
        """A successful login is reported once and reconciliation proceeds."""
        result, report, calls = self.run_controller(case="login-ok")
        self.assert_phase(result, report, "PHASE: authentication succeeded "
                          "credentials=ocm-token attempts=1 exit=0")
        self.assertIn("Phase 1: Reading desired state", result.stderr)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("rosa-cluster-lease-config ConfigMap not found", result.stderr)
        self.assertEqual(len(self.commands(calls, "ocm")), 1)
        self.assertEqual(self.commands(calls, "sleep"), [])
        self.assertTrue(self.commands(calls, "oc"))

    def test_login_retry_is_reported_without_extra_attempts(self):
        """A login that succeeds on the second attempt reports one retry."""
        result, report, calls = self.run_controller(case="login-retry-ok")
        self.assert_phase(result, report, "PHASE: authentication succeeded "
                          "credentials=ocm-token attempts=2 exit=0")
        self.assertEqual(len(self.commands(calls, "ocm")), 2)
        self.assertEqual(self.commands(calls, "sleep"), [["sleep", "10"]])

    def test_report_destination_cannot_mask_the_failure(self):
        """An absent, unusable or unset destination changes neither status nor log."""
        for artifacts in ("absent", "blocked", "unset"):
            with self.subTest(artifacts=artifacts):
                result, report, calls = self.run_controller(artifacts=artifacts)
                self.assertEqual(result.returncode, LOGIN_EXIT, result.stderr)
                self.assertIsNone(report)
                self.assertIn("PHASE: authentication failed "
                              f"credentials=ocm-token attempts=3 exit={LOGIN_EXIT}", result.stderr)
                self.assertEqual(len(self.commands(calls, "ocm")), 3)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unwritable_destination_cannot_mask_the_failure(self):
        """A directory the step cannot write to is handled like an absent one."""
        result, report, calls = self.run_controller(artifacts="unwritable")
        self.assertEqual(result.returncode, LOGIN_EXIT, result.stderr)
        self.assertIsNone(report)
        self.assertIn("PHASE: authentication failed "
                      f"credentials=ocm-token attempts=3 exit={LOGIN_EXIT}", result.stderr)
        self.assertEqual(len(self.commands(calls, "ocm")), 3)

    def test_unreportable_run_stops_before_reconciling(self):
        """Reconciliation reports what it does, so it must not start unreported."""
        for artifacts in ("absent", "blocked", "unset"):
            with self.subTest(artifacts=artifacts):
                result, report, calls = self.run_controller(case="login-ok", artifacts=artifacts)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIsNone(report)
                self.assertIn("refusing to reconcile", result.stderr)
                self.assertNotIn("Phase 1: Reading desired state", result.stderr)
                self.assertEqual(self.commands(calls, "oc"), [])
                self.assertEqual(len(self.commands(calls, "ocm")), 1)

    def test_phase_reporting_rejects_unexpected_values(self):
        """Only the fixed words and integers may ever be reported."""
        self.prepare("normal")
        report = self.artifacts / "controller-report.txt"
        hostile = f"{CANARY} --token {CANARY}"
        result = subprocess.run(
            ["bash", "-c", f'source "{self.script}"\n'
                           f'OCM_LOGIN_CREDENTIAL_MODE="{hostile}"\n'
                           f'report_phase "{hostile}" "{hostile}" "{hostile}" "{hostile}"\n'],
            env={"PATH": os.defpath, "HOME": str(self.base), "ARTIFACT_DIR": str(self.artifacts)},
            capture_output=True, text=True, timeout=120, check=True)
        line = "PHASE: unknown unknown credentials=unknown attempts=0 exit=0"
        self.assertIn(line, result.stderr)
        self.assertEqual(report.read_text(encoding="utf-8"), line + "\n")
        self.assert_sanitized(result, report.read_text(encoding="utf-8"))


if __name__ == "__main__":
    if sys.argv[1:2] == ["--mock"]:
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
