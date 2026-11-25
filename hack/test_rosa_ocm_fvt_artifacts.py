#!/usr/bin/env python3
"""Offline fixtures for the delivered step: python3 hack/test_rosa_ocm_fvt_artifacts.py.

The prepare and run refs' commands are delivered through their normal shared path.
Metadata describes the outer collector identity, not the nested image's identity.
Scans stop at 128 entries, 16 result locations and 32 reports per location; labels
omit result names and phase timestamps. Report contents are never read by collection.
"""

import errno
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/rosa/e2e/ocm-fvt"
SECRET = "FIXTURE_SECRET_DO_NOT_PRINT"
DIGEST = "sha256:" + "a" * 64
IMAGE_ID = "sha256:" + "b" * 64
REVISION = "c" * 40
SOURCE = "https://github.com/openshift-online/rosa-backend-tests"
IMAGE_REPOSITORY = "quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests"


def mock_artifact_command(command, arguments, base, case):
    output_record = base / "output-path"
    output = Path(output_record.read_text()) if output_record.exists() else base / "artifacts/ocm-fvt-results"
    if command == "find":
        if case == "find-failure" and arguments == [
                str(output), "-type", "f", "-name", "report.xml", "-print0"]:
            print(SECRET, file=sys.stderr)
            return 94
        os.execv("/usr/bin/find", ["find", *arguments])
    if command == "cp":
        if case == "copy-failure" and arguments[-1] == str(
                base / "artifacts/junit-ocm-fvt-report.xml"):
            print(SECRET, file=sys.stderr)
            return 91
        os.execv("/bin/cp", ["cp", *arguments])
    if command == "python3":
        if case == "provenance-failure" and arguments == [
                "-", str(base / "artifacts"), IMAGE_ID, IMAGE_REPOSITORY]:
            return 95
        if case == "collector-failure" and arguments == [
                str(base / "shared/ocm-fvt-artifacts.py"), "metadata",
                str(output), str(base / "artifacts/ocm-fvt-artifact-metadata.json")]:
            return 92
        os.execv(sys.executable, [sys.executable, *arguments])
    raise AssertionError("Unexpected artifact fixture command")


def mock_image_inspection(case):
    """Emit projected metadata, including malformed byte and digest fixtures."""
    data = {"image_id": IMAGE_ID, "manifest_digest": DIGEST,
            "repo_digests": [IMAGE_REPOSITORY + "@" + DIGEST],
            "revision": REVISION, "source": SOURCE}
    if case == "invalid-utf8-inspect":
        payload = json.dumps(data).encode("utf-8").replace(REVISION.encode("ascii"), b"\xff" + REVISION.encode("ascii"))
        os.write(sys.stdout.fileno(), payload)
        return 0
    if case == "multibyte-boundary-inspect":
        prefix = (json.dumps(data)[:-1] + ', "unrelated":"' + SECRET).encode("utf-8")
        payload = prefix + b"a" * (16384 - len(prefix)) + '\u20ac"}'.encode("utf-8")
        os.write(sys.stdout.fileno(), payload)
        return 0
    if case == "invalid-digest":
        data["repo_digests"] = [SECRET]
    elif case == "ambiguous-digest":
        data["repo_digests"].append(IMAGE_REPOSITORY + "@sha256:" + "d" * 64)
        data["manifest_digest"] = None
    elif case == "index-and-manifest-digests":
        data["repo_digests"].insert(0, IMAGE_REPOSITORY + "@sha256:" + "d" * 64)
    elif case == "wrong-repository":
        data["repo_digests"] = ["unrelated@" + DIGEST]
    elif case == "id-mismatch":
        data["image_id"] = "sha256:" + "d" * 64
    elif case == "missing-labels":
        data["revision"], data["source"] = None, None
    elif case == "invalid-labels":
        data["revision"], data["source"] = SECRET, "https://github.com/" + SECRET
    elif case == "oversized-inspect":
        data["source"] = SECRET * 2000
    if case == "malformed-inspect":
        print(SECRET)
    elif case not in ("inspect-failure", "inspect-timeout"):
        print(json.dumps(data))
    if case == "inspect-timeout":
        return 124
    return 93 if case == "inspect-failure" else 0


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    output = base / "artifacts/ocm-fvt-results"
    if command in ("cat", "env"):
        if ((command == "cat" and arguments[0].startswith("/usr/local/cs-qe-credentials/"))
                or (command == "env" and arguments[0] == "-i")):
            return 0
        os.execv("/usr/bin/" + command, [command, *arguments])
    if command in ("find", "cp", "python3"):
        return mock_artifact_command(command, arguments, base, case)
    if command != "podman":
        raise AssertionError("Unexpected fixture command")
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps(arguments) + "\n")
    if arguments[0] == "pull":
        print(SECRET if case == "invalid-pull-id" else IMAGE_ID[7:])
        return 96 if case == "pull-failure" else 0
    if arguments[0] == "inspect":
        return mock_image_inspection(case)
    if arguments[0] != "run":
        raise AssertionError("Unexpected podman operation")
    output = Path(next(argument.rsplit(":", 2)[0] for argument in arguments
                       if argument.endswith(":/ocm-backend-tests/output:z")))
    (base / "output-path").write_text(str(output), encoding="utf-8")
    if case == "missing":
        output.rmdir()
    elif case == "root-symlink":
        output.rmdir()
        output.symlink_to(base / "outside", target_is_directory=True)
    elif case == "root-unreadable":
        output.chmod(0)
    else:
        result = output / "test-result-fixture"
        result.mkdir(mode=0o755)
        (result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        (result / "pre-cluster-creation_123456.json").write_text(SECRET, encoding="utf-8")
        (result / "pre-cluster-creation_123456.json").chmod(0)
        if case in ("copy-failure", "find-failure"):
            (output / ".datainfo").mkdir()
            (result / "cluster.ini").write_text(
                "ID=fixture-cluster\nState=installing\n", encoding="utf-8")
            (result / SECRET).mkdir()
            (result / "report.xml").rename(result / SECRET / "report.xml")
        if case == "unreadable":
            result.chmod(0)
        elif case == "symlinks":
            (result / "report.xml").unlink()
            (result / "report.xml").symlink_to(base / "outside/secret")
            (output / "test-result-linked").symlink_to(base / "outside", target_is_directory=True)
        elif case == "unexpected":
            (output / ("test-result-" + SECRET + "\nname")).mkdir()
            for name in (SECRET, "pre-cluster-creation_123456.json\n" + SECRET,
                         "pre-" + SECRET + "_123456.xml"):
                (result / name).write_text(SECRET, encoding="utf-8")
        elif case in ("bounded", "bounded-reports"):
            for index in range(40):
                (result / f"post-clean_{index:06d}.xml").write_text(SECRET, encoding="utf-8")
            if case == "bounded":
                for index in range(40):
                    (output / f"test-result-{index}").mkdir()
        elif case in ("output-entry-limit", "result-entry-limit"):
            scan_directory = output if case == "output-entry-limit" else result
            for index in range(150):
                (scan_directory / f"ignored-{index}").touch()
    return int(os.environ["FIXTURE_EXIT"])


class ArtifactFixture(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.artifacts = self.base / "artifacts"
        self.artifacts.mkdir()
        self.shared = self.base / "shared"
        self.shared.mkdir()
        (self.base / "outside").mkdir()
        (self.base / "outside/secret").write_text(SECRET, encoding="utf-8")
        ref = (STEP / "rosa-e2e-ocm-fvt-ref.yaml").read_text(encoding="utf-8")
        commands = next(line.split(": ", 1)[1] for line in ref.splitlines()
                        if line.startswith("  commands: "))
        self.script = self.base / commands
        shutil.copyfile(STEP / commands, self.script)
        prepare = STEP / "prepare"
        prepare_ref = (prepare / "rosa-e2e-ocm-fvt-prepare-ref.yaml").read_text(encoding="utf-8")
        prepare_command = next(line.split(": ", 1)[1] for line in prepare_ref.splitlines()
                               if line.startswith("  commands: "))
        delivered_prepare = self.base / prepare_command
        shutil.copyfile(prepare / prepare_command, delivered_prepare)
        subprocess.run([sys.executable, str(delivered_prepare)],
                       env={**os.environ, "SHARED_DIR": str(self.shared)}, check=True)
        for command in ("podman", "cat", "env", "cp", "find", "python3"):
            executable = self.bin / command
            executable.write_text(
                f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" '
                f'--mock {command} "$@"\n', encoding="utf-8")
            executable.chmod(0o755)

    def run_step(self, case="normal", exit_code=0, pull_error=False):
        result = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base), "ARTIFACT_DIR": str(self.artifacts),
            "SHARED_DIR": str(self.shared), "JOB_NAME": "fixture", "BUILD_ID": "1",
            "OCM_FVT_JOB_NAME": "fixture", "FIXTURE_DIR": str(self.base),
            "FIXTURE_CASE": case, "FIXTURE_EXIT": str(exit_code),
            "OCM_FVT_DEFER_CLEAN": str(case in ("copy-failure", "find-failure")).lower(),
        }, capture_output=True, text=True, timeout=30, umask=0o077, check=False)
        self.assertEqual(result.returncode, exit_code, result.stderr)
        calls = [json.loads(line) for line in (self.base / "calls.jsonl").read_text().splitlines()]
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        if pull_error:
            self.assertEqual([call[0] for call in calls], ["pull"])
            self.assertFalse((self.shared / "ocm-fvt-exit-code").exists())
            return result
        self.assertEqual((self.shared / "ocm-fvt-exit-code").read_text().strip(), str(exit_code))
        self.assertEqual([call[0] for call in calls], ["pull", "inspect", "run"])
        self.assertIn("--quiet", calls[0])
        self.assertEqual(calls[0][-1], IMAGE_REPOSITORY + ":latest")
        self.assertEqual(calls[1][-1], IMAGE_ID)
        self.assertEqual(calls[2][calls[2].index("ocmtest") - 1], IMAGE_ID)
        self.assertIn("--pull=never", calls[2])
        self.assertNotIn(":latest", " ".join(calls[1]))
        self.assertNotIn(":latest", " ".join(calls[2]))
        self.assertNotIn(".Config.Env", calls[1][calls[1].index("--format") + 1])
        self.assertIn("{{json .ID}}", calls[1][calls[1].index("--format") + 1])
        output = Path((self.base / "output-path").read_text())
        self.assertFalse(output.is_relative_to(self.artifacts))
        self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)
        env_file = Path(calls[-1][calls[-1].index("--env-file") + 1])
        self.assertFalse(env_file.exists(), "EXIT trap must still remove the temporary env file")
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def provenance(self):
        path = self.artifacts / "ocm-fvt-runner-provenance.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        contents = path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET, contents)
        self.assertLess(len(contents), 2048)
        return json.loads(contents)

    def metadata(self):
        path = self.artifacts / "ocm-fvt-artifact-metadata.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        self.assertEqual(path.stat().st_uid, os.geteuid())
        contents = path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET, contents)
        self.assertNotIn(str(self.base), contents)
        self.assertNotIn("test-result-", contents)
        self.assertLess(len(contents), 65000)
        return json.loads(contents)

    def tearDown(self):
        record = self.base / "output-path"
        outputs = [self.artifacts / "ocm-fvt-results"]
        if record.exists():
            outputs.append(Path(record.read_text()))
        for output in outputs:
            if output.is_dir() and not output.is_symlink():
                output.chmod(0o700)
                result = output / "test-result-fixture"
                if result.is_dir():
                    result.chmod(0o700)


class ArtifactMetadataTests(ArtifactFixture):
    def test_failed_test_status(self):
        self.run_step(exit_code=42)
        self.metadata()

    def test_standard_failure_status(self):
        self.run_step(exit_code=1)
        self.metadata()

    def test_signal_status(self):
        self.run_step(exit_code=137)
        self.metadata()

    def test_identity_and_reports(self):
        self.run_step()
        data = self.metadata()
        self.assertEqual(data["collector"]["euid"], os.geteuid())
        self.assertEqual(data["collector"]["egid"], os.getegid())
        self.assertEqual(data["collector"]["groups"], os.getgroups()[:32])
        self.assertEqual(data["output"]["mode"], "1777")
        directory = data["output"]["results"][0]
        self.assertEqual(directory["uid"], os.geteuid())
        reports = {report["label"]: report for report in directory["reports"]}
        self.assertEqual(set(reports), {"merged-xml", "pre-cluster-creation-json"})
        self.assertEqual(reports["pre-cluster-creation-json"]["mode"], "0000")
        digest = self.artifacts / "ocm-fvt-image-digest.txt"
        self.assertEqual(digest.read_text().strip(), DIGEST)
        self.assertEqual(stat.S_IMODE(digest.stat().st_mode), 0o644)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_directory(self):
        self.run_step("unreadable", 42)
        directory = self.metadata()["output"]["results"][0]
        self.assertEqual(directory["mode"], "0000")
        self.assertEqual(directory["errno"], errno.EACCES)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_root(self):
        self.run_step("root-unreadable")
        self.assertEqual(self.metadata()["output"]["errno"], errno.EACCES)

    def test_missing_output(self):
        self.run_step("missing", 42)
        self.assertEqual(self.metadata()["output"], {"errno": errno.ENOENT})

    def test_bounded_output_entry_scan(self):
        self.run_step("output-entry-limit")
        self.assertTrue(self.metadata()["output"]["truncated"])

    def test_symlink_root(self):
        self.run_step("root-symlink")
        self.assertEqual(self.metadata()["output"]["type"], stat.S_IFLNK)
        self.assertNotIn("results", self.metadata()["output"])


class RunnerInspectionEncodingTests(ArtifactFixture):
    """Exercise fail-closed byte decoding through the delivered launcher."""

    def check_undecodable_inspection(self, case, exit_code, expected_status):
        """Require explicit unknown artifacts without changing the suite result."""
        self.run_step(case, exit_code)
        data = self.provenance()
        self.assertEqual(data["inspection_status"], expected_status)
        self.assertEqual(data["digest"], "unknown")
        self.assertEqual(data["org.opencontainers.image.revision"], "unknown")
        self.assertEqual(data["org.opencontainers.image.source"], "unknown")
        self.assertFalse((self.artifacts / "ocm-fvt-image-digest.txt").exists())

    def test_invalid_utf8_preserves_success(self):
        """Reject undecodable bytes even inside an otherwise valid revision."""
        self.check_undecodable_inspection("invalid-utf8-inspect", 0, "unknown_invalid_response")

    def test_invalid_utf8_preserves_failure(self):
        """Keep the failing suite exit when inspection bytes cannot decode."""
        self.check_undecodable_inspection("invalid-utf8-inspect", 42, "unknown_invalid_response")

    def test_multibyte_boundary_preserves_success(self):
        """Classify a byte-cap split UTF-8 character as a response limit."""
        self.check_undecodable_inspection("multibyte-boundary-inspect", 0, "unknown_response_limit")

    def test_multibyte_boundary_preserves_failure(self):
        """Keep a failing suite exit when the byte cap splits UTF-8."""
        self.check_undecodable_inspection("multibyte-boundary-inspect", 42, "unknown_response_limit")


class RunnerProvenanceTests(ArtifactFixture):
    def test_pulled_image_is_inspected_and_executed_not_mutable_tag(self):
        self.run_step(exit_code=42)
        data = self.provenance()
        self.assertEqual(data["executed_image_id"], IMAGE_ID)
        self.assertEqual(data["digest"], DIGEST)
        self.assertEqual(data["immutable_ref"], IMAGE_REPOSITORY + "@" + DIGEST)
        self.assertEqual(data["org.opencontainers.image.revision"], REVISION)
        self.assertEqual(data["org.opencontainers.image.source"], SOURCE)
        self.assertEqual(data["label_semantics"], "image_metadata_not_executable_attestation")

    def test_inspection_failure_preserves_test_status(self):
        self.run_step("inspect-failure", 42)
        self.assertEqual(self.provenance()["inspection_status"], "unknown_unavailable")

    def test_inspection_timeout_preserves_success(self):
        result = self.run_step("inspect-timeout")
        self.assertEqual(self.provenance()["inspection_status"], "unknown_unavailable")
        self.assertIn("WARNING: failed to get ocmci image digest", result.stdout)

    def test_inspection_timeout_preserves_failure(self):
        self.run_step("inspect-timeout", 42)
        self.assertEqual(self.provenance()["inspection_status"], "unknown_unavailable")

    def test_provenance_collector_failure_preserves_success(self):
        result = self.run_step("provenance-failure")
        self.assertFalse((self.artifacts / "ocm-fvt-runner-provenance.json").exists())
        self.assertIn("WARNING: failed to collect ocm-fvt runner provenance", result.stdout)

    def test_provenance_collector_failure_preserves_failure(self):
        result = self.run_step("provenance-failure", 42)
        self.assertIn("WARNING: failed to collect ocm-fvt runner provenance", result.stdout)

    def test_malformed_inspection_is_explicit(self):
        self.run_step("malformed-inspect")
        self.assertEqual(self.provenance()["inspection_status"], "unknown_invalid_response")

    def test_inspection_limit_is_explicit(self):
        self.run_step("oversized-inspect", 42)
        self.assertIn(self.provenance()["inspection_status"],
                      ("unknown_response_limit", "unknown_unavailable"))

    def test_identity_mismatch_does_not_attribute_labels(self):
        self.run_step("id-mismatch")
        data = self.provenance()
        self.assertEqual(data["inspection_status"], "unknown_identity_mismatch")
        self.assertEqual(data["org.opencontainers.image.revision"], "unknown")
        self.assertEqual(data["digest"], "unknown")

    def test_missing_labels_are_explicit(self):
        self.run_step("missing-labels", 42)
        data = self.provenance()
        self.assertEqual(data["revision_status"], "unknown_missing_or_invalid")
        self.assertEqual(data["source_status"], "unknown_missing_or_unapproved")
        self.assertEqual(data["digest"], DIGEST)

    def test_invalid_labels_are_not_published(self):
        self.run_step("invalid-labels")
        data = self.provenance()
        self.assertEqual(data["org.opencontainers.image.revision"], "unknown")
        self.assertEqual(data["org.opencontainers.image.source"], "unknown")

    def test_ambiguous_digest_is_unknown(self):
        self.run_step("ambiguous-digest")
        self.assertEqual(self.provenance()["digest"], "unknown")

    def test_local_manifest_disambiguates_index_and_platform_digests(self):
        self.run_step("index-and-manifest-digests")
        self.assertEqual(self.provenance()["digest"], DIGEST)

    def test_unrelated_repository_digest_is_unknown(self):
        self.run_step("wrong-repository")
        self.assertEqual(self.provenance()["digest"], "unknown")

    def test_invalid_pull_id_refuses_unbound_execution(self):
        self.run_step("invalid-pull-id", 1, pull_error=True)

    def test_pull_failure_preserves_status(self):
        self.run_step("pull-failure", 96, pull_error=True)

    def test_provenance_write_failure_preserves_test_status(self):
        (self.artifacts / "ocm-fvt-runner-provenance.json").symlink_to(self.base / "outside/secret")
        result = self.run_step(exit_code=42)
        self.assertIn("WARNING: failed to persist ocm-fvt runner provenance", result.stdout)
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)
        self.assertEqual((self.artifacts / "ocm-fvt-image-digest.txt").read_text().strip(), DIGEST)


class ArtifactSafetyTests(ArtifactFixture):
    def test_symlink_results_and_reports(self):
        self.run_step("symlinks")
        directories = self.metadata()["output"]["results"]
        self.assertTrue(any(directory["type"] == stat.S_IFLNK for directory in directories))
        reports = [report for directory in directories for report in directory.get("reports", [])]
        self.assertTrue(any(report["type"] == stat.S_IFLNK for report in reports))
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)

    def test_unexpected_names_and_contents_are_not_published(self):
        self.run_step("unexpected")
        self.assertEqual(sum(len(directory["reports"]) for directory in
                             self.metadata()["output"]["results"]), 2)

    def test_bounded_metadata(self):
        self.run_step("bounded")
        output = self.metadata()["output"]
        self.assertTrue(output["truncated"])
        self.assertEqual(len(output["results"]), 16)
        self.assertTrue(all(len(directory["reports"]) <= 32 for directory in output["results"]))

    def test_bounded_result_entry_scan(self):
        self.run_step("result-entry-limit")
        results = self.metadata()["output"]["results"]
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0]["truncated"])

    def test_bounded_report_metadata(self):
        self.run_step("bounded-reports")
        directory = self.metadata()["output"]["results"][0]
        self.assertTrue(directory["truncated"])
        self.assertEqual(len(directory["reports"]), 32)

    def test_collector_does_not_follow_existing_artifact_symlink(self):
        artifact = self.artifacts / "ocm-fvt-artifact-metadata.json"
        artifact.symlink_to(self.base / "outside/secret")
        result = self.run_step()
        self.assertTrue(artifact.is_symlink())
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)

    def test_digest_does_not_follow_existing_artifact_symlink(self):
        artifact = self.artifacts / "ocm-fvt-image-digest.txt"
        artifact.symlink_to(self.base / "outside/secret")
        self.run_step()
        self.assertTrue(artifact.is_symlink())
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)

    def test_artifact_symlinks_to_special_files_are_not_followed(self):
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt", "ocm-fvt-runner-provenance.json"):
            (self.artifacts / name).symlink_to("/dev/null")
        result = self.run_step(exit_code=42)
        self.assertIn("WARNING: failed to persist ocmci image digest", result.stdout)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)

    def test_existing_fifos_do_not_block_artifact_creation(self):
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt", "ocm-fvt-runner-provenance.json"):
            os.mkfifo(self.artifacts / name)
        result = self.run_step()
        self.assertIn("WARNING: failed to persist ocmci image digest", result.stdout)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)

    def test_existing_artifact_files_are_not_overwritten(self):
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt", "ocm-fvt-runner-provenance.json"):
            (self.artifacts / name).write_text(SECRET, encoding="utf-8")
        self.run_step()
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt", "ocm-fvt-runner-provenance.json"):
            self.assertEqual((self.artifacts / name).read_text(), SECRET)

    def test_invalid_digest_is_not_published(self):
        self.run_step("invalid-digest")
        self.assertFalse((self.artifacts / "ocm-fvt-image-digest.txt").exists())

    def test_inspect_failure_is_best_effort(self):
        self.run_step("inspect-failure")
        self.metadata()


class ArtifactPostprocessingTests(ArtifactFixture):
    def check_report_failure(self, case, exit_code):
        result = self.run_step(case, exit_code)
        self.metadata()
        operation = "copy ocm-fvt report" if case == "copy-failure" else "scan ocm-fvt reports"
        self.assertIn("WARNING: failed to " + operation, result.stdout)
        self.assertFalse((self.artifacts / "junit-ocm-fvt-report.xml").exists())
        self.assertEqual((self.shared / "cluster-id").read_text(), "fixture-cluster")
        for directory in (self.shared, self.artifacts):
            self.assertEqual((directory / "ocm-fvt-gather-eligible").read_text(), "false")
            self.assertEqual((directory / "ocm-fvt-job-name").read_text(), "fixture")
            with tarfile.open(directory / "ocm-fvt-clean-state.tgz") as archive:
                self.assertIn("test-result-fixture/cluster.ini", archive.getnames())
                self.assertIn(".datainfo", archive.getnames())

    def test_later_copy_failure_preserves_test_status(self):
        self.check_report_failure("copy-failure", 0)

    def test_later_copy_failure_preserves_failed_test_status(self):
        self.check_report_failure("copy-failure", 42)

    def test_later_find_failure_preserves_test_status(self):
        self.check_report_failure("find-failure", 0)

    def test_later_find_failure_preserves_failed_test_status(self):
        self.check_report_failure("find-failure", 42)

    def check_collector_failure(self, exit_code):
        result = self.run_step("collector-failure", exit_code)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)
        self.assertNotIn("WARNING: failed to persist ocmci image digest", result.stdout)
        self.assertFalse((self.artifacts / "ocm-fvt-artifact-metadata.json").exists())
        self.assertEqual((self.artifacts / "ocm-fvt-image-digest.txt").read_text(), DIGEST + "\n")

    def test_collector_failure_preserves_test_status(self):
        self.check_collector_failure(42)

    def test_collector_failure_does_not_fail_successful_test(self):
        self.check_collector_failure(0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
