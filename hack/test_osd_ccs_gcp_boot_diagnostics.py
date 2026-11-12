#!/usr/bin/env python3
"""Offline fixtures for the delivered step: python3 hack/test_osd_ccs_gcp_boot_diagnostics.py.

Only the ref's commands script is copied into the fixture, matching step
delivery. Every gcloud invocation is mocked; the tests never reach a cloud API,
never read a real credential and never require network access.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/osd-ccs/gather/gcp-boot-diagnostics"
WORKFLOW = (REPOSITORY / "ci-operator/step-registry/rosa/e2e/osd-gcp"
            / "rosa-e2e-osd-gcp-workflow.yaml")

SECRET = "FIXTURE_SECRET_DO_NOT_PUBLISH"
CLUSTER = "ci-osd-gcp-ab12"
PROJECT = "osd-ccs-fixture-project"
ZONE = "us-east1-b"
ZONE_URL = "https://www.googleapis.com/compute/v1/projects/%s/zones/%s" % (PROJECT, ZONE)
MASTER = CLUSTER + "-abcde-master-0"
WORKER = CLUSTER + "-abcde-worker-a-xyz12"
FOREIGN = "other-cluster-9999-worker-0"

SERIAL_WITH_SIGNALS = "\n".join([
    "[    0.000000] Linux version 5.14.0 fixture",
    "[    4.100000] ignition[700]: Ignition v2.16.2",
    "[    6.200000] systemd[1]: Started ignition-fetch.service - Ignition (fetch).",
    "[    7.300000] systemd[1]: Starting ignition-files.service - Ignition (files)...",
    "[    9.400000] systemd[1]: Failed to start ignition-files.service - Ignition (files).",
    "[    9.500000] ignition[800]: Ignition failed: resource requirements not met",
    "[   11.000000] systemd[1]: kubelet.service: Main process exited, code=exited",
    "[   12.000000] token=%s" % SECRET,
    "[   13.000000] systemd[1]: Started crio.service - Container Runtime Interface.",
    "[   14.000000] systemd[1]: Reached target Multi-User System.",
    "",
])

SERIAL_WITHOUT_UNITS = "\n".join([
    "[    0.000000] Linux version 5.14.0 fixture",
    "[    1.000000] nothing interesting happened here",
    "[    2.000000] password=%s" % SECRET,
    "",
])

SERIAL_ONLY_STARTING = "\n".join([
    "[    1.000000] systemd[1]: Starting kubelet.service - Kubernetes Kubelet...",
    "",
])

SERIAL_FAILED_THEN_STARTED = "\n".join([
    "[    1.000000] systemd[1]: Failed to start kubelet.service - Kubernetes Kubelet.",
    "[    2.000000] systemd[1]: Started kubelet.service - Kubernetes Kubelet.",
    "",
])

# One line, no newline, with many "reached target" occurrences. A marker matcher
# that backtracks turns this into quadratic work; see the wall-clock assertion.
SERIAL_LONG_LINE = "reached target foo " * 15000

# Larger than the collector's 4 MiB read bound, again with no newline.
SERIAL_OVERSIZED = "x" * (5 * 1024 * 1024)


def instance_listing(case):
    if case == "out-of-scope":
        entries = [{"name": FOREIGN, "zone": ZONE_URL, "status": "RUNNING"}]
    elif case == "mixed-scope":
        entries = [
            {"name": WORKER, "zone": ZONE_URL, "status": "RUNNING"},
            {"name": FOREIGN, "zone": ZONE_URL, "status": "RUNNING"},
            {"name": CLUSTER + "-bad_name", "zone": ZONE_URL, "status": "RUNNING"},
            {"name": CLUSTER + "-ok-zone", "zone": "not a zone", "status": "RUNNING"},
            "not-a-dict",
        ]
    elif case == "empty-listing":
        entries = []
    elif case == "hostile-status":
        entries = [{"name": WORKER, "zone": ZONE_URL,
                    "status": "RUNNING; " + SECRET}]
    elif case == "many-instances":
        entries = [{"name": "%s-abcde-worker-%02d" % (CLUSTER, index),
                    "zone": ZONE_URL, "status": "RUNNING"} for index in range(12)]
    elif case == "two-digit-region":
        entries = [{"name": WORKER,
                    "zone": ZONE_URL.replace("/" + ZONE, "/europe-west12-a"),
                    "status": "RUNNING"}]
    else:
        entries = [
            {"name": MASTER, "zone": ZONE_URL, "status": "RUNNING"},
            {"name": WORKER, "zone": ZONE_URL, "status": "PROVISIONING"},
        ]
    return json.dumps(entries)


def mock_gcloud(arguments):
    """Stand in for the gcloud CLI. Never contacts a cloud API."""
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps(arguments) + "\n")

    if arguments[:2] == ["auth", "activate-service-account"]:
        if case == "auth-denied":
            print("ERROR: PERMISSION_DENIED for %s" % SECRET, file=sys.stderr)
            return 1
        return 0

    if arguments[:3] == ["compute", "instances", "list"]:
        if case == "discovery-denied":
            print("ERROR: 403 Forbidden %s" % SECRET, file=sys.stderr)
            return 1
        if case == "discovery-garbage":
            print("{not json" + SECRET)
            return 0
        print(instance_listing(case))
        return 0

    if arguments[:3] == ["compute", "instances", "get-serial-port-output"]:
        name = arguments[-1]
        if case == "serial-denied":
            print("ERROR: 403 does not have compute.instances.getSerialPortOutput "
                  "%s" % SECRET, file=sys.stderr)
            return 1
        if case == "serial-timeout":
            time.sleep(10)
            return 0
        if case == "serial-partial" and name == WORKER:
            print("ERROR: 404 instance not found %s" % SECRET, file=sys.stderr)
            return 1
        if case == "serial-empty":
            return 0
        if case == "no-units":
            sys.stdout.write(SERIAL_WITHOUT_UNITS)
            return 0
        if case == "only-starting":
            sys.stdout.write(SERIAL_ONLY_STARTING)
            return 0
        if case == "failed-then-started":
            sys.stdout.write(SERIAL_FAILED_THEN_STARTED)
            return 0
        if case == "long-line":
            sys.stdout.write(SERIAL_LONG_LINE)
            return 0
        if case == "oversized":
            sys.stdout.write(SERIAL_OVERSIZED)
            return 0
        sys.stdout.write(SERIAL_WITH_SIGNALS)
        return 0

    raise AssertionError("Unexpected gcloud invocation")


class StepFixture(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base, True)
        self.bin = self.base / "bin"
        self.artifacts = self.base / "artifacts"
        self.shared = self.base / "shared"
        self.profile = self.base / "profile"
        self.tmp = self.base / "tmp"
        for directory in (self.bin, self.artifacts, self.shared, self.profile, self.tmp):
            directory.mkdir()

        ref = (STEP / "osd-ccs-gather-gcp-boot-diagnostics-ref.yaml").read_text(
            encoding="utf-8")
        commands = next(line.split(": ", 1)[1].strip() for line in ref.splitlines()
                        if line.startswith("  commands: "))
        self.script = self.base / commands
        shutil.copyfile(STEP / commands, self.script)

        shim = self.bin / "gcloud"
        shim.write_text(
            '#!/bin/bash\nexec "%s" "%s" --mock gcloud "$@"\n'
            % (sys.executable, Path(__file__).resolve()), encoding="utf-8")
        shim.chmod(0o755)

        (self.shared / "cluster-name").write_text(CLUSTER + "\n", encoding="utf-8")
        (self.profile / "osd-ccs-gcp.json").write_text(
            json.dumps({"project_id": PROJECT, "private_key": SECRET}), encoding="utf-8")

    def run_step(self, case="normal", enabled=True, **overrides):
        environment = {
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base),
            "TMPDIR": str(self.tmp),
            "ARTIFACT_DIR": str(self.artifacts),
            "SHARED_DIR": str(self.shared),
            "CLUSTER_PROFILE_DIR": str(self.profile),
            "FIXTURE_DIR": str(self.base),
            "FIXTURE_CASE": case,
            "OSD_CCS_GATHER_GCP_BOOT_DIAGNOSTICS": "true" if enabled else "false",
        }
        environment.update(overrides)
        result = subprocess.run(["bash", str(self.script)], env=environment,
                                capture_output=True, text=True, timeout=120,
                                check=False)
        # The step must never block the deprovision steps that follow it.
        self.assertEqual(result.returncode, 0, result.stderr)
        combined = result.stdout + result.stderr
        self.assertNotIn(SECRET, combined)
        for identifier in (MASTER, WORKER, FOREIGN, PROJECT, ZONE):
            self.assertNotIn(identifier, combined)
        # The private scratch directory must not survive the step.
        self.assertEqual(sorted(entry.name for entry in self.tmp.iterdir()), [])
        self.assert_nothing_leaked()
        return result

    def assert_nothing_leaked(self):
        """Nothing anywhere under ARTIFACT_DIR or SHARED_DIR may carry raw data.

        Checked recursively rather than only inside the step's own output
        directory, so that a stray write elsewhere cannot pass unnoticed.
        """
        published = []
        for root in (self.artifacts, self.shared):
            for path in sorted(root.rglob("*")):
                if not path.is_file() or path.is_symlink():
                    continue
                relative = path.relative_to(root).as_posix()
                if root is self.artifacts:
                    published.append(relative)
                body = path.read_text(encoding="utf-8", errors="replace")
                self.assertNotIn(SECRET, body, "secret leaked into %s" % relative)
                for identifier in (MASTER, WORKER, FOREIGN, PROJECT, ZONE):
                    self.assertNotIn(identifier, body,
                                     "identifier leaked into %s" % relative)
                self.assertNotIn("Linux version", body)
                self.assertNotIn("reached target", body.lower())
        self.assertEqual(published, ["gcp-boot-diagnostics/collection-outcome.json"],
                         "the step must create no file other than its outcome document")

    def calls(self):
        path = self.base / "calls.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def outcome(self):
        self.assert_nothing_leaked()
        path = self.artifacts / "gcp-boot-diagnostics/collection-outcome.json"
        contents = path.read_text(encoding="utf-8")
        # No secret, no raw serial text and no resource identity may be published.
        self.assertNotIn(SECRET, contents)
        for identifier in (MASTER, WORKER, FOREIGN, PROJECT, ZONE, CLUSTER):
            self.assertNotIn(identifier, contents)
        self.assertNotIn("Linux version", contents)
        self.assertNotIn("ignition[", contents)
        return json.loads(contents)


class DisabledByDefaultTests(StepFixture):
    def blocking_credential(self):
        """Replace the credential with a FIFO that blocks any reader forever.

        A permission bit would not prove anything here: the step does not use
        errexit, so a failed read would pass silently. Reading this FIFO can
        only end in the test's own timeout, so the test fails loudly if the
        disabled path ever touches the credential.
        """
        path = self.profile / "osd-ccs-gcp.json"
        path.unlink()
        os.mkfifo(path, 0o600)
        return path

    def test_absent_switch_performs_no_credential_or_cloud_access(self):
        self.blocking_credential()
        result = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base), "TMPDIR": str(self.tmp),
            "ARTIFACT_DIR": str(self.artifacts), "SHARED_DIR": str(self.shared),
            "CLUSTER_PROFILE_DIR": str(self.profile), "FIXTURE_DIR": str(self.base),
            "FIXTURE_CASE": "normal",
        }, capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [], "disabled must issue no gcloud call")
        self.assertEqual(self.outcome(),
                         {"schema": 1, "collector": "disabled",
                          "reason": "opt_in_required"})

    def test_enabled_path_does_not_block_on_a_non_regular_credential(self):
        self.blocking_credential()
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "credential_unavailable")
        self.assertEqual(self.calls(), [])

    def test_non_true_values_stay_disabled(self):
        for value in ("false", "", "TRUE", "yes", "1", "true ", "0"):
            with self.subTest(value=value):
                shutil.rmtree(self.artifacts)
                self.artifacts.mkdir()
                (self.base / "calls.jsonl").unlink(missing_ok=True)
                self.run_step(enabled=False,
                              OSD_CCS_GATHER_GCP_BOOT_DIAGNOSTICS=value)
                self.assertEqual(self.calls(), [])
                self.assertEqual(self.outcome()["collector"], "disabled")

    def test_enabled_switch_is_exactly_true(self):
        self.run_step()
        self.assertNotEqual(self.calls(), [])
        self.assertEqual(self.outcome()["collector"], "complete")


class IdentityTests(StepFixture):
    def test_missing_cluster_name_fails_closed(self):
        (self.shared / "cluster-name").unlink()
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "identity_unavailable")
        self.assertEqual(self.calls(), [], "no cloud call without an identity")

    def test_ambiguous_cluster_name_fails_closed(self):
        (self.shared / "cluster-name").write_text("a-one\na-two\n", encoding="utf-8")
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "identity_ambiguous")
        self.assertEqual(self.calls(), [])

    def test_malformed_cluster_name_fails_closed(self):
        for value in ("Bad-Name", "x", "-leading", "name with space",
                      "a" * 40, "inject;rm -rf /", "*"):
            with self.subTest(value=value):
                shutil.rmtree(self.artifacts)
                self.artifacts.mkdir()
                (self.shared / "cluster-name").write_text(value + "\n", encoding="utf-8")
                self.run_step()
                self.assertEqual(self.outcome()["reason"], "identity_malformed")
                self.assertEqual(self.calls(), [])

    def test_resolving_symlinked_cluster_name_is_refused(self):
        # The link target must exist and be valid, otherwise the test would
        # pass through is_file() and prove nothing about the symlink guard.
        target = self.base / "elsewhere-cluster-name"
        target.write_text(CLUSTER + "\n", encoding="utf-8")
        (self.shared / "cluster-name").unlink()
        (self.shared / "cluster-name").symlink_to(target)
        self.assertTrue((self.shared / "cluster-name").is_file(),
                        "fixture must present a resolving symlink")
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "identity_unavailable")
        self.assertEqual(self.calls(), [])

    def test_resolving_symlinked_credential_is_refused(self):
        target = self.base / "elsewhere-credential.json"
        target.write_text(json.dumps({"project_id": PROJECT}), encoding="utf-8")
        path = self.profile / "osd-ccs-gcp.json"
        path.unlink()
        path.symlink_to(target)
        self.assertTrue(path.is_file(), "fixture must present a resolving symlink")
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "credential_unavailable")
        self.assertEqual(self.calls(), [])

    def test_credential_project_id_must_be_well_formed(self):
        for value in ("X", "no", 123, None, "bad project", "-leading"):
            with self.subTest(value=value):
                shutil.rmtree(self.artifacts)
                self.artifacts.mkdir()
                (self.profile / "osd-ccs-gcp.json").write_text(
                    json.dumps({"project_id": value}), encoding="utf-8")
                self.run_step()
                self.assertEqual(self.outcome()["reason"], "credential_malformed")
                self.assertEqual(self.calls(), [])

    def test_malformed_credential_fails_closed(self):
        (self.profile / "osd-ccs-gcp.json").write_text("{}", encoding="utf-8")
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "credential_malformed")
        self.assertEqual(self.calls(), [], "no cloud call without a usable project")

    def test_missing_credential_fails_closed(self):
        (self.profile / "osd-ccs-gcp.json").unlink()
        self.run_step()
        self.assertEqual(self.outcome()["reason"], "credential_unavailable")


class ScopeTests(StepFixture):
    def test_only_this_runs_instances_are_read(self):
        self.run_step()
        reads = [call for call in self.calls()
                 if call[:3] == ["compute", "instances", "get-serial-port-output"]]
        self.assertEqual([call[-1] for call in reads], [MASTER, WORKER])
        for call in reads:
            self.assertEqual(call[call.index("--project") + 1], PROJECT)
            self.assertEqual(call[call.index("--zone") + 1], ZONE)

    def test_two_digit_regions_are_in_scope(self):
        self.run_step(case="two-digit-region")
        data = self.outcome()
        self.assertEqual(data["instances_discovered"], 1)
        self.assertEqual(data["instances_rejected_out_of_scope"], 0)
        read = next(call for call in self.calls() if "get-serial-port-output" in call)
        self.assertEqual(read[read.index("--zone") + 1], "europe-west12-a")

    def test_instance_count_is_bounded(self):
        self.run_step(case="many-instances")
        reads = [call for call in self.calls() if "get-serial-port-output" in call]
        self.assertEqual(len(reads), 8, "max_instances must actually bind")
        self.assertEqual(len(self.outcome()["instances"]), 8)

    def test_discovery_is_filtered_to_this_run(self):
        self.run_step()
        listing = next(call for call in self.calls()
                       if call[:3] == ["compute", "instances", "list"])
        self.assertIn("name:%s-*" % CLUSTER, listing)
        self.assertIn(PROJECT, listing)

    def test_foreign_instances_are_rejected_not_read(self):
        self.run_step(case="out-of-scope")
        data = self.outcome()
        self.assertEqual(data["instances_discovered"], 0)
        self.assertEqual(data["instances_rejected_out_of_scope"], 1)
        self.assertEqual(data["reason"], "discovery_out_of_scope")
        self.assertEqual([call for call in self.calls()
                          if "get-serial-port-output" in call], [])

    def test_mixed_listing_keeps_only_in_scope_entries(self):
        self.run_step(case="mixed-scope")
        data = self.outcome()
        self.assertEqual(data["instances_discovered"], 1)
        self.assertEqual(data["instances_rejected_out_of_scope"], 4)
        reads = [call[-1] for call in self.calls() if "get-serial-port-output" in call]
        self.assertEqual(reads, [WORKER])

    def test_empty_listing_is_an_explicit_outcome(self):
        self.run_step(case="empty-listing")
        data = self.outcome()
        self.assertEqual(data["reason"], "no_instances_in_scope")
        self.assertEqual(data["collector"], "complete")

    def test_unparseable_listing_fails_closed(self):
        self.run_step(case="discovery-garbage")
        self.assertEqual(self.outcome()["reason"], "discovery_invalid_response")


class FailurePathTests(StepFixture):
    def test_auth_denied(self):
        self.run_step(case="auth-denied")
        self.assertEqual(self.outcome()["reason"], "auth_permission_denied")

    def test_discovery_denied(self):
        self.run_step(case="discovery-denied")
        self.assertEqual(self.outcome()["reason"], "discovery_permission_denied")

    def test_serial_permission_denied_is_graceful(self):
        self.run_step(case="serial-denied")
        data = self.outcome()
        self.assertEqual(data["collector"], "complete")
        self.assertEqual([record["collection"] for record in data["instances"]],
                         ["permission_denied", "permission_denied"])
        self.assertEqual(data["instances_examined"], 0)

    def test_partial_collection_keeps_the_successful_instance(self):
        self.run_step(case="serial-partial")
        data = self.outcome()
        self.assertEqual([record["collection"] for record in data["instances"]],
                         ["ok", "not_found"])
        self.assertEqual(data["instances_examined"], 1)

    def test_timeout_is_bounded_and_graceful(self):
        started = time.monotonic()
        self.run_step(case="serial-timeout",
                      OSD_CCS_GATHER_GCP_BOOT_CALL_TIMEOUT_SECONDS="2",
                      OSD_CCS_GATHER_GCP_BOOT_BUDGET_SECONDS="6")
        self.assertLess(time.monotonic() - started, 20)
        data = self.outcome()
        self.assertEqual(data["collector"], "complete")
        self.assertIn("timeout", [record["collection"] for record in data["instances"]])

    def test_out_of_range_limits_fall_back_to_defaults(self):
        self.run_step(OSD_CCS_GATHER_GCP_BOOT_MAX_INSTANCES="99999",
                      OSD_CCS_GATHER_GCP_BOOT_BUDGET_SECONDS="not-a-number",
                      OSD_CCS_GATHER_GCP_BOOT_CALL_TIMEOUT_SECONDS="-5")
        limits = self.outcome()["limits"]
        self.assertEqual(limits["max_instances"], 8)
        self.assertEqual(limits["budget_seconds"], 240)
        self.assertEqual(limits["call_timeout_seconds"], 45)


class SignalTests(StepFixture):
    def test_boot_signals_are_parsed_into_fixed_values(self):
        self.run_step()
        data = self.outcome()
        self.assertEqual(data["reason"], "collected")
        self.assertEqual(data["instances_examined"], 2)
        signals = data["instances"][0]["signals"]
        self.assertEqual(signals["parse"], "ok")
        units = signals["units"]
        self.assertEqual(units["ignition-fetch.service"]["status"],
                         "started_signal_observed")
        self.assertEqual(units["ignition-files.service"]["status"],
                         "failed_signal_observed")
        self.assertEqual(units["kubelet.service"]["status"], "failed_signal_observed")
        self.assertEqual(units["crio.service"]["status"], "started_signal_observed")
        # Never observed in this capture, so unknown rather than healthy.
        self.assertEqual(units["nodeip-configuration.service"]["status"], "no_signal")
        markers = signals["markers"]
        self.assertEqual(markers["ignition_failure"], 1)
        self.assertEqual(markers["multi_user_target"], 1)
        self.assertEqual(markers["kernel_panic"], 0)

    def test_instance_state_is_an_enum_and_records_are_indexed(self):
        self.run_step()
        records = self.outcome()["instances"]
        self.assertEqual([record["index"] for record in records], [0, 1])
        self.assertEqual([record["instance_state"] for record in records],
                         ["RUNNING", "PROVISIONING"])

    def test_hostile_instance_state_is_clamped_to_unknown(self):
        # outcome() already fails if SECRET reached the document; this pins the
        # reason it cannot: listing values are clamped to a fixed vocabulary.
        self.run_step(case="hostile-status")
        self.assertEqual(self.outcome()["instances"][0]["instance_state"], "unknown")

    def test_a_unit_that_only_attempts_to_start_is_not_reported_as_started(self):
        self.run_step(case="only-starting")
        units = self.outcome()["instances"][0]["signals"]["units"]
        self.assertEqual(units["kubelet.service"]["status"], "start_attempt_observed")

    def test_a_later_start_does_not_erase_an_observed_failure(self):
        self.run_step(case="failed-then-started")
        units = self.outcome()["instances"][0]["signals"]["units"]
        self.assertEqual(units["kubelet.service"]["status"], "failed_signal_observed")

    def test_line_count_is_exact(self):
        self.run_step()
        signals = self.outcome()["instances"][0]["signals"]
        self.assertEqual(signals["lines_scanned"],
                         len(SERIAL_WITH_SIGNALS.splitlines()))
        self.assertFalse(signals["lines_truncated"])

    def test_a_single_enormous_line_stays_bounded_and_fast(self):
        # Regression: a marker matcher that backtracks made this quadratic, and
        # the read bound did not apply to a capture containing no newline.
        started = time.monotonic()
        self.run_step(case="long-line")
        self.assertLess(time.monotonic() - started, 20,
                        "hostile single-line serial output must not blow the budget")
        signals = self.outcome()["instances"][0]["signals"]
        self.assertEqual(signals["parse"], "ok")
        self.assertEqual(signals["lines_scanned"], 1)

    def test_output_larger_than_the_read_bound_is_truncated(self):
        self.run_step(case="oversized")
        record = self.outcome()["instances"][0]
        self.assertTrue(record["bytes_truncated"])
        self.assertTrue(record["signals"]["lines_truncated"])
        # The reader must stop at the bound rather than consume all 5 MiB.
        self.assertEqual(record["signals"]["characters_scanned"], 4 * 1024 * 1024)

    def test_normal_output_is_read_in_full(self):
        self.run_step()
        signals = self.outcome()["instances"][0]["signals"]
        self.assertEqual(signals["characters_scanned"], len(SERIAL_WITH_SIGNALS))

    def test_output_without_known_units_reports_no_signal(self):
        self.run_step(case="no-units")
        signals = self.outcome()["instances"][0]["signals"]
        self.assertTrue(all(unit["status"] == "no_signal"
                            for unit in signals["units"].values()))
        self.assertTrue(all(count == 0 for count in signals["markers"].values()))
        self.assertGreater(signals["lines_scanned"], 0)

    def test_empty_serial_output_is_no_signal(self):
        self.run_step(case="serial-empty")
        data = self.outcome()
        self.assertEqual([record["collection"] for record in data["instances"]],
                         ["no_signal", "no_signal"])

    def test_outcome_states_the_signal_limitation(self):
        self.run_step()
        disclaimer = self.outcome()["disclaimer"]
        self.assertIn("not", disclaimer)
        self.assertIn("authoritative current systemd state", disclaimer)
        self.assertIn("never healthy", disclaimer)
        self.assertIn("do not establish a root cause", disclaimer)


class WorkflowTests(unittest.TestCase):
    @staticmethod
    def phase(name):
        """Return the ordered step entries of one workflow phase.

        Indentation is tracked so that the assertion pins the collector to the
        post phase, rather than matching the same ref anywhere in the file.
        """
        entries = []
        indent = None
        for line in WORKFLOW.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if indent is None:
                if stripped == name + ":":
                    indent = len(line) - len(line.lstrip())
                continue
            current = len(line) - len(line.lstrip())
            if stripped and current <= indent:
                break
            if stripped.startswith(("- ref:", "- chain:")):
                entries.append(stripped)
        return entries

    def test_collector_runs_in_post_before_the_cluster_is_deleted(self):
        post = self.phase("post")
        self.assertIn("- ref: osd-ccs-gather-gcp-boot-diagnostics", post)
        collector = post.index("- ref: osd-ccs-gather-gcp-boot-diagnostics")
        deprovision = post.index("- ref: osd-ccs-cluster-deprovision")
        wif = post.index("- ref: osd-ccs-gcp-wif-config-deprovision")
        self.assertLess(collector, deprovision,
                        "boot signals must be collected before the cluster is deleted")
        self.assertLess(deprovision, wif)

    def test_collector_is_not_in_pre_or_test(self):
        for name in ("pre", "test"):
            self.assertNotIn("- ref: osd-ccs-gather-gcp-boot-diagnostics",
                             self.phase(name),
                             "the collector only has instances to read in post")

    def test_collector_is_best_effort_like_its_neighbours(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        marker = "- ref: osd-ccs-gather-gcp-boot-diagnostics\n        best_effort: true"
        self.assertIn(marker, text)

    def test_step_declares_no_additional_credentials(self):
        ref = (STEP / "osd-ccs-gather-gcp-boot-diagnostics-ref.yaml").read_text(
            encoding="utf-8")
        self.assertNotIn("credentials:", ref,
                         "this change must not add a credential mount")
        self.assertIn("- name: OSD_CCS_GATHER_GCP_BOOT_DIAGNOSTICS\n"
                      '    default: "false"\n', ref,
                      "the opt-in switch itself must default to false")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--mock":
        sys.exit(mock_gcloud(sys.argv[3:]))
    unittest.main()
