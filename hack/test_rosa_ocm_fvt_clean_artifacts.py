#!/usr/bin/env python3
"""Offline fixtures for the deferred clean step: python3 hack/test_rosa_ocm_fvt_clean_artifacts.py.

The ocmci container writes /ocm-backend-tests/output as the image user, so Prow's
sidecar - which censors every artifact as the step user by creating a tmp-censor
file inside the directory holding it - cannot process a directory the step user may
not write into. These fixtures reproduce that permission with result directories the
collector can read but not write, run the real commands script with podman mocked,
and assert that nothing the censor cannot rewrite ever reaches ARTIFACT_DIR while the
cleanup container's own exit status is preserved.
"""

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
CLEAN = STEP / "clean"
HELPER = STEP / "prepare/rosa-e2e-ocm-fvt-prepare-commands.py"
SECRET = "FIXTURE_SECRET_DO_NOT_PRINT"
PUBLISHED = "ocm-fvt-clean-results"


def produce_output(output, case):
    """Write the tree the ocmci container would leave behind in its output mount."""
    result = output / "test-result-fixture"
    result.mkdir()
    (result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
    (result / "post-clean_000001.xml").write_text("<testsuite name='post-clean'/>\n",
                                                  encoding="utf-8")
    (result / "post-clean_000001.json").write_text('{"leaked": 0}\n', encoding="utf-8")
    if case == "hostile":
        (output / ".datainfo/kube-configs").mkdir(parents=True, exist_ok=True)
        (output / ".datainfo/kube-configs/fixture.kubeconfig").write_text(
            SECRET, encoding="utf-8")
        (output / "cluster.ini").write_text("ID=fixture-cluster\n", encoding="utf-8")
        (result / "admin.kubeconfig").write_text(SECRET, encoding="utf-8")
        (result / "escape.txt").symlink_to(output.parent.parent / "outside/secret")
        (result / "dangling.log").symlink_to("/nowhere")
        (output / "linked-result").symlink_to(output.parent.parent / "outside",
                                              target_is_directory=True)
        os.mkfifo(result / "pipe.fifo")
    if case == "unreadable":
        (result / "private").mkdir()
        (result / "private/secret.log").write_text(SECRET, encoding="utf-8")
        (result / "private").chmod(0)
    # The image user's umask leaves the collector able to read the tree but unable
    # to create the censor's temporary file anywhere inside it.
    for directory, _, names in os.walk(result):
        for name in names:
            path = Path(directory) / name
            if path.is_file() and not path.is_symlink():
                path.chmod(0o444)
    result.chmod(0o555)


def mock_podman(arguments, base, case):
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps(arguments) + "\n")
    if arguments[0] == "pull":
        return 0
    if arguments[0] == "image":
        print("sha256:" + "a" * 64)
        return 0
    if arguments[0] != "run":
        raise AssertionError("Unexpected podman operation")
    if "--entrypoint" in arguments:
        print("998")
        return 0
    mounts = [arguments[index + 1] for index, value in enumerate(arguments) if value == "-v"]
    output = Path(next(mount.split(":")[0] for mount in mounts
                       if ":/ocm-backend-tests/output" in mount))
    (base / "mounted.json").write_text(json.dumps(sorted(os.listdir(output))), encoding="utf-8")
    if case != "empty":
        produce_output(output, case)
    return int(os.environ["FIXTURE_EXIT"])


def mock_mktemp(arguments, base, case):
    """Keep the step's private fallback directory inside the fixture."""
    if arguments[:1] == ["-d"] and arguments[1].startswith("/tmp/ocm-fvt-clean."):
        if case == "mktemp-failure":
            return 97
        fallback = base / "fallback"
        fallback.mkdir(exist_ok=True)
        arguments = ["-d", str(fallback / Path(arguments[1]).name)]
    os.execv("/usr/bin/mktemp", ["mktemp", *arguments])
    raise AssertionError("Unreachable")


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    if command == "mktemp":
        return mock_mktemp(arguments, base, case)
    if command in ("cat", "env"):
        if ((command == "cat" and arguments[0].startswith("/usr/local/cs-qe-credentials/"))
                or (command == "env" and arguments[0] == "-i")):
            return 0
        os.execv("/usr/bin/" + command, [command, *arguments])
    if command == "python3":
        if case == "stage-failure" and arguments[1] == "stage":
            print(SECRET, file=sys.stderr)
            return 95
        if case == "publish-failure" and arguments[1] == "publish":
            print(SECRET, file=sys.stderr)
            return 96
        os.execv(sys.executable, [sys.executable, *arguments])
    if command != "podman":
        raise AssertionError("Unexpected fixture command")
    return mock_podman(arguments, base, case)


def censor_errors(root):
    """Report what the Prow sidecar censor could not rewrite under root."""
    failures = []
    for directory, _, names in os.walk(root):
        for name in names:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                failures.append("not a regular file: " + str(path))
                continue
            try:
                handle, temporary = tempfile.mkstemp(prefix="tmp-censor", dir=directory)
            except OSError as error:
                failures.append(
                    f"could not create temporary file for censoring {path}: {error.strerror}")
                continue
            os.close(handle)
            try:
                os.replace(temporary, path)
            except OSError as error:
                failures.append(f"could not censor {path}: {error.strerror}")
                os.unlink(temporary)
    return failures


class CleanFixture(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        # Cleanups run last in, first out: restore modes before removing the tree.
        self.addCleanup(shutil.rmtree, self.base)
        self.addCleanup(self.restore_modes)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.artifacts = self.base / "job/artifacts"
        self.artifacts.mkdir(parents=True)
        self.shared = self.base / "shared"
        self.shared.mkdir()
        (self.base / "outside").mkdir()
        (self.base / "outside/secret").write_text(SECRET, encoding="utf-8")
        ref = (CLEAN / "rosa-e2e-ocm-fvt-clean-ref.yaml").read_text(encoding="utf-8")
        commands = next(line.split(": ", 1)[1] for line in ref.splitlines()
                        if line.startswith("  commands: "))
        self.script = self.base / commands
        shutil.copyfile(CLEAN / commands, self.script)
        self.write_clean_state()
        for command in ("podman", "cat", "env", "python3", "mktemp"):
            executable = self.bin / command
            executable.write_text(
                f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" '
                f'--mock {command} "$@"\n', encoding="utf-8")
            executable.chmod(0o755)

    def write_clean_state(self):
        """Persist the tarball the test step hands to the deferred clean step."""
        staged = self.base / "state"
        (staged / "rosa-hcp-profile").mkdir(parents=True)
        (staged / ".datainfo/kube-configs").mkdir(parents=True)
        (staged / "rosa-hcp-profile/cluster.ini").write_text(
            "ID=fixture-cluster\nState=ready\n", encoding="utf-8")
        (staged / ".datainfo/kube-configs/fixture.kubeconfig").write_text(
            SECRET, encoding="utf-8")
        with tarfile.open(self.shared / "ocm-fvt-clean-state.tgz", "w:gz") as archive:
            archive.add(staged / "rosa-hcp-profile", arcname="rosa-hcp-profile")
            archive.add(staged / ".datainfo", arcname=".datainfo")

    def install_helper(self, kind="file"):
        delivered = self.shared / "ocm-fvt-artifacts.py"
        if kind == "file":
            shutil.copyfile(HELPER, delivered)
        elif kind == "symlink":
            delivered.symlink_to(HELPER)

    def run_step(self, case="normal", exit_code=0, helper="file"):
        self.install_helper(helper)
        result = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base), "ARTIFACT_DIR": str(self.artifacts),
            "SHARED_DIR": str(self.shared), "JOB_NAME": "fixture", "BUILD_ID": "1",
            "OCM_FVT_JOB_NAME": "fixture", "FIXTURE_DIR": str(self.base),
            "FIXTURE_CASE": case, "FIXTURE_EXIT": str(exit_code),
        }, capture_output=True, text=True, timeout=60, umask=0o077, check=False)
        self.assertEqual(result.returncode, exit_code, result.stderr)
        calls = [json.loads(line) for line in (self.base / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(calls[0][0], "pull")
        self.assertEqual(calls[-1][0], "run")
        env_file = Path(calls[-1][calls[-1].index("--env-file") + 1])
        self.assertFalse(env_file.exists(), "EXIT trap must still remove the temporary env file")
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def mounted_output(self):
        """What the container saw in its output mount before it ran."""
        return json.loads((self.base / "mounted.json").read_text(encoding="utf-8"))

    def entries(self, root=None):
        root = root or self.artifacts
        found = []
        for directory, names, files in os.walk(root):
            for name in names + files:
                found.append(str((Path(directory) / name).relative_to(root)))
        return sorted(found)

    def assert_collector_owns_artifacts(self):
        for entry in self.entries():
            info = (self.artifacts / entry).lstat()
            self.assertEqual(info.st_uid, os.geteuid(), entry)
            self.assertFalse(stat.S_IMODE(info.st_mode) & 0o022, entry)
        self.assertEqual(censor_errors(self.artifacts), [])

    def restore_modes(self, root=None):
        for directory, names, _ in os.walk(root or self.base):
            for name in names:
                path = Path(directory) / name
                if not path.is_symlink():
                    path.chmod(0o700)

    def remove_fallback_directories(self, existing):
        """Drop any /tmp fallback the step created when mktemp was unavailable."""
        for path in set(Path("/tmp").glob("ocm-fvt-clean.*")) - existing:
            self.restore_modes(path)
            shutil.rmtree(path, ignore_errors=True)


class CleanPublicationTests(CleanFixture):
    def test_successful_clean_publishes_censorable_results(self):
        self.run_step()
        published = self.entries()
        self.assertIn(PUBLISHED + "/test-result-fixture/report.xml", published)
        self.assertIn(PUBLISHED + "/test-result-fixture/post-clean_000001.json", published)
        self.assert_collector_owns_artifacts()

    def test_failed_clean_still_publishes_and_preserves_status(self):
        self.run_step(exit_code=7)
        self.assertIn(PUBLISHED + "/test-result-fixture/post-clean_000001.xml", self.entries())
        self.assert_collector_owns_artifacts()

    def test_container_output_is_staged_outside_the_artifact_directory(self):
        self.run_step()
        for entry in self.entries():
            self.assertFalse(entry.startswith(".ocm-fvt-"), entry)
        self.assertTrue(any(child.name.startswith(".ocm-fvt-")
                            for child in self.artifacts.parent.iterdir()))

    def test_persisted_clean_state_is_restored_for_the_container(self):
        self.run_step()
        self.assertEqual(self.mounted_output(), [".datainfo", "rosa-hcp-profile"])

    def test_empty_output_publishes_an_empty_result_directory(self):
        self.run_step("empty")
        self.assertTrue((self.artifacts / PUBLISHED).is_dir())
        self.assert_collector_owns_artifacts()


class CleanSafetyTests(CleanFixture):
    def test_censor_probe_detects_container_owned_results(self):
        """The regression this step fixes: unwritable results break censoring."""
        exposed = self.artifacts / PUBLISHED / "test-result-fixture"
        exposed.mkdir(parents=True)
        (exposed / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        exposed.chmod(0o555)
        failures = censor_errors(self.artifacts)
        self.assertTrue(any("temporary file for censoring" in failure for failure in failures),
                        failures)

    def test_symlinks_and_special_files_are_not_published(self):
        self.run_step("hostile")
        for entry in self.entries():
            path = self.artifacts / entry
            self.assertFalse(path.is_symlink(), entry)
            self.assertTrue(path.is_dir() or path.is_file(), entry)
        self.assertEqual((self.base / "outside/secret").read_text(encoding="utf-8"), SECRET)
        self.assert_collector_owns_artifacts()

    def test_credential_material_is_not_published(self):
        self.run_step("hostile")
        for entry in self.entries(self.artifacts / PUBLISHED):
            name = Path(entry).name
            self.assertNotIn(".datainfo", Path(entry).parts, entry)
            self.assertNotEqual(name, "cluster.ini", entry)
            self.assertNotEqual(name, "kubeconfig", entry)
            self.assertFalse(name.endswith(".kubeconfig"), entry)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_output_is_excluded_without_failing_the_step(self):
        result = self.run_step("unreadable")
        self.assertNotIn("secret.log", str(self.entries()))
        self.assertIn("unreadable or non-regular", result.stdout)
        self.assert_collector_owns_artifacts()

    def test_missing_helper_keeps_cleanup_and_publishes_nothing(self):
        result = self.run_step(helper="none")
        self.assertIn("were not prepared", result.stdout)
        self.assertNotIn(PUBLISHED, self.entries())
        self.assert_collector_owns_artifacts()

    def test_symlinked_helper_is_not_executed(self):
        result = self.run_step(helper="symlink")
        self.assertIn("were not prepared", result.stdout)
        self.assertNotIn(PUBLISHED, self.entries())

    def test_unavailable_mktemp_still_runs_cleanup_and_preserves_status(self):
        existing = set(Path("/tmp").glob("ocm-fvt-clean.*"))
        self.addCleanup(self.remove_fallback_directories, existing)
        result = self.run_step("mktemp-failure", exit_code=4, helper="none")
        self.assertIn("were not prepared", result.stdout)
        self.assertNotIn(PUBLISHED, self.entries())
        self.assert_collector_owns_artifacts()

    def test_staging_failure_keeps_cleanup_and_preserves_status(self):
        result = self.run_step("stage-failure", exit_code=5)
        self.assertIn("failed to stage", result.stdout)
        self.assertNotIn(PUBLISHED, self.entries())
        self.assert_collector_owns_artifacts()

    def test_publication_failure_keeps_output_private_and_preserves_status(self):
        result = self.run_step("publish-failure", exit_code=9)
        self.assertIn("WARNING: failed to publish", result.stdout)
        self.assertNotIn(PUBLISHED, self.entries())
        self.assert_collector_owns_artifacts()

    def test_existing_destination_is_not_overwritten(self):
        (self.artifacts / PUBLISHED).mkdir()
        (self.artifacts / PUBLISHED / "kept.txt").write_text("kept\n", encoding="utf-8")
        result = self.run_step(exit_code=3)
        self.assertIn("WARNING: failed to publish", result.stdout)
        self.assertEqual(self.entries(self.artifacts / PUBLISHED), ["kept.txt"])


class HelperDestinationTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)

    def publish(self, *destination):
        artifacts = Path(tempfile.mkdtemp(dir=self.base))
        output = Path(tempfile.mkdtemp(dir=self.base)) / "output"
        output.mkdir()
        (output / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        result = subprocess.run([sys.executable, str(HELPER), "publish", str(output),
                                 str(artifacts), *destination],
                                capture_output=True, text=True, timeout=60, check=False)
        return result, artifacts

    def test_default_destination_is_unchanged_for_the_test_step(self):
        result, artifacts = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((artifacts / "ocm-fvt-results/report.xml").is_file())

    def test_named_destination_is_published(self):
        result, artifacts = self.publish(PUBLISHED)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((artifacts / PUBLISHED / "report.xml").is_file())

    def test_destinations_outside_the_artifact_directory_are_rejected(self):
        for destination in ("../escape", "escape/nested", ".", "..", "", "-rf", "x" * 65):
            result, artifacts = self.publish(destination)
            self.assertNotEqual(result.returncode, 0, destination)
            self.assertEqual(os.listdir(artifacts), [], destination)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
