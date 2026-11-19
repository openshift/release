#!/usr/bin/env python3
"""Offline fixtures for the publication audit manifest and the exit-code artifact:

    python3 hack/test_rosa_ocm_fvt_publication_audit.py

The delivered helper is run as the step runs it, as a separate process on a
real directory tree, so the manifest these assertions read is the one the step
would hand to the Prow sidecar. The exit-code tests run the step script itself
with podman and the credential reads mocked. Nothing here contacts a cluster, a
registry or GCS, and no fixture content reaches the manifest.
"""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/rosa/e2e/ocm-fvt"
HELPERS = STEP / "prepare/rosa-e2e-ocm-fvt-prepare-commands.py"
AUDIT = "ocm-fvt-artifact-audit.json"
EXIT_CODE_ARTIFACT = "ocm-fvt-exit-code"
PUBLISHED_DIR = "ocm-fvt-results"
DIGEST = "sha256:" + "a" * 64
# Mirrors AUDIT_MAX_ENTRIES in the helper. The cap is the reason the exclusion
# counts exist, so a test that fills it has to know where it is.
MAX_ENTRIES = 512
SECRET = "FIXTURE_SECRET_DO_NOT_PRINT"
UNPRIVILEGED = unittest.skipIf(os.geteuid() == 0,
                               "Permission denial requires an unprivileged fixture user")


class PublicationFixture(unittest.TestCase):
    """A staged output tree and an artifact directory, published as the step does."""

    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(self.cleanup)
        self.workdir = self.base / ".ocm-fvt-fixture"
        self.workdir.mkdir()
        self.output = self.workdir / "output"
        self.output.mkdir()
        self.artifacts = self.base / "artifacts"
        self.artifacts.mkdir()
        self.result = self.output / "test-result-fixture"
        self.result.mkdir()

    def cleanup(self):
        for directory in (self.output, self.result, self.artifacts / PUBLISHED_DIR):
            if directory.is_dir() and not directory.is_symlink():
                directory.chmod(0o700)
        shutil.rmtree(self.base, ignore_errors=True)

    def publish(self, *extra, returncode=0):
        process = subprocess.run(
            [sys.executable, "-I", str(HELPERS), "publish", str(self.output),
             str(self.artifacts), *extra],
            capture_output=True, text=True, timeout=120, check=False)
        self.assertEqual(process.returncode, returncode, process.stderr)
        self.assertNotIn(SECRET, process.stdout + process.stderr)
        return process

    def manifest(self):
        contents = (self.artifacts / AUDIT).read_text(encoding="utf-8")
        self.assertNotIn(SECRET, contents)
        return json.loads(contents)

    def assert_excluded(self, manifest, **counts):
        expected = {"irregular": 0, "unreadable": 0}
        expected.update(counts)
        self.assertEqual(manifest["publication"]["excluded"], expected)

    def dispositions(self, manifest, disposition):
        return [record for record in manifest["entries"]
                if record["disposition"] == disposition]


class PublicationCompletenessTests(PublicationFixture):
    """The publication record has to say how much publication could not copy."""

    def test_complete_publication_counts_no_exclusion(self):
        (self.result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        process = self.publish()
        manifest = self.manifest()
        self.assertEqual(manifest["publication"]["outcome"], "published")
        self.assert_excluded(manifest)
        self.assertNotIn("excluded from publication", process.stdout)

    @UNPRIVILEGED
    def test_unreadable_file_is_counted_and_recorded(self):
        (self.result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        tunnel = self.result / "tunnel.log"
        tunnel.write_text(SECRET, encoding="utf-8")
        tunnel.chmod(0)
        process = self.publish()
        manifest = self.manifest()
        self.assertEqual(manifest["publication"]["outcome"], "published")
        self.assert_excluded(manifest, unreadable=1)
        self.assertIn("WARNING: unreadable or non-regular ocm-fvt artifacts excluded",
                      process.stdout)
        excluded = self.dispositions(manifest, "excluded")
        self.assertEqual([record["reason"] for record in excluded], ["unreadable"])
        self.assertFalse((self.artifacts / PUBLISHED_DIR
                          / "test-result-fixture/tunnel.log").exists())

    @UNPRIVILEGED
    def test_unreadable_directory_is_counted(self):
        (self.result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        self.result.chmod(0)
        self.publish()
        self.assert_excluded(self.manifest(), unreadable=1)

    def test_irregular_entry_is_counted(self):
        os.mkfifo(self.result / "pipe")
        process = self.publish()
        manifest = self.manifest()
        self.assert_excluded(manifest, irregular=1)
        self.assertIn("WARNING: unreadable or non-regular ocm-fvt artifacts excluded",
                      process.stdout)
        self.assertEqual([record["reason"] for record in
                          self.dispositions(manifest, "excluded")], ["irregular"])

    def test_exclusions_are_counted_rather_than_flagged(self):
        """A per-reason count has to say how often, not merely whether."""
        for index in range(3):
            os.mkfifo(self.result / f"pipe-{index}")
        self.publish()
        self.assert_excluded(self.manifest(), irregular=3)

    def test_exclusion_survives_the_entry_cap(self):
        """The record naming the excluded entry may be dropped; the count may not.

        Without the count a reader of a capped manifest sees an outcome of
        published and no excluded record, which is what a run that published
        everything also looks like. The excluded entry is a FIFO rather than
        an unreadable file so that the one test proving the count is taken
        before the cap also runs for a privileged fixture user.
        """
        for index in range(MAX_ENTRIES):
            (self.result / f"entry-{index:05d}.txt").write_text("x", encoding="utf-8")
        # Sorts after every published entry, so the cap is what drops it.
        os.mkfifo(self.result / "zz-pipe")
        self.publish()
        manifest = self.manifest()
        self.assertEqual(manifest["publication"]["outcome"], "published")
        self.assert_excluded(manifest, irregular=1)
        self.assertEqual(len(manifest["entries"]), MAX_ENTRIES)
        # The result directory has a record of its own, so the cap discards
        # the last published entry along with the excluded one.
        self.assertEqual(manifest["limits"]["records_dropped"], 2)
        self.assertEqual(self.dispositions(manifest, "excluded"), [])

    def test_refused_publication_keeps_its_counts(self):
        (self.artifacts / PUBLISHED_DIR).mkdir()
        os.mkfifo(self.result / "pipe")
        self.publish(returncode=1)
        manifest = self.manifest()
        self.assertEqual(manifest["publication"]["outcome"], "failed")
        self.assertEqual(manifest["publication"]["reason"], "destination-exists")
        self.assert_excluded(manifest, irregular=1)

    def test_private_state_is_not_publication_incompleteness(self):
        (self.output / ".datainfo").mkdir()
        (self.result / "cluster.ini").write_text("ID=fixture\n", encoding="utf-8")
        (self.result / "fixture.kubeconfig").write_text(SECRET, encoding="utf-8")
        process = self.publish()
        manifest = self.manifest()
        self.assert_excluded(manifest)
        self.assertNotIn("excluded from publication", process.stdout)
        rules = sorted(record["rule"] for record in self.dispositions(manifest, "excluded"))
        self.assertEqual(rules, ["cluster-ini", "datainfo", "kubeconfig-named"])

    def test_counts_are_reported_for_a_named_destination(self):
        os.mkfifo(self.result / "pipe")
        self.publish("ocm-fvt-clean-results")
        manifest = self.manifest()
        self.assertEqual(manifest["publication"]["destination"], "ocm-fvt-clean-results")
        self.assert_excluded(manifest, irregular=1)


def mock_command(command, arguments):
    """Stand in for podman and the credential reads so the step runs offline."""
    if command in ("cat", "env"):
        credential = (command == "cat"
                      and arguments[0].startswith("/usr/local/cs-qe-credentials/"))
        if credential or (command == "env" and arguments[0] == "-i"):
            return 0
        os.execv("/usr/bin/" + command, [command, *arguments])
    if command != "podman":
        raise AssertionError("Unexpected fixture command: " + command)
    if arguments[0] == "pull":
        return 0
    if arguments[0] == "inspect":
        print("fixture@" + DIGEST)
        return 0
    if arguments[0] != "run":
        raise AssertionError("Unexpected podman operation: " + arguments[0])
    # The step stages its own private output directory beside ARTIFACT_DIR and
    # bind-mounts only that, so the fixture writes where the real suite would.
    for staged in Path(os.environ["FIXTURE_DIR"]).glob(".ocm-fvt-*/output"):
        result = staged / "test-result-fixture"
        result.mkdir()
        (result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
    return int(os.environ["FIXTURE_EXIT"])


class ExitCodeArtifactTests(unittest.TestCase):
    """The suite's exit status has to survive as a published artifact.

    SHARED_DIR is not uploaded to GCS, and the only in-repository consumer of
    SHARED_DIR/ocm-fvt-exit-code is the OSDFM stage-promotion post step, so
    these assertions cover both copies: the promotion handoff must keep
    working, and the published copy must be a plain integer the collector can
    read whatever the step inherited.
    """

    def setUp(self):
        self.base = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.base, True)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.artifacts = self.base / "artifacts"
        self.artifacts.mkdir()
        self.shared = self.base / "shared"
        self.shared.mkdir()
        self.outside = self.base / "outside"
        self.outside.write_text(SECRET, encoding="utf-8")
        # Copy the script the ref actually names, so the fixture cannot drift
        # onto a file the registry does not deliver.
        ref = (STEP / "rosa-e2e-ocm-fvt-ref.yaml").read_text(encoding="utf-8")
        commands = next(line.split(": ", 1)[1] for line in ref.splitlines()
                        if line.startswith("  commands: "))
        self.script = self.base / commands
        shutil.copyfile(STEP / commands, self.script)
        # Deliver the helper exactly as the prepare step does.
        subprocess.run([sys.executable, "-I", str(HELPERS)], check=True, timeout=60,
                       env={**os.environ, "SHARED_DIR": str(self.shared)})
        for command in ("podman", "cat", "env"):
            executable = self.bin / command
            executable.write_text(
                f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" '
                f'--mock {command} "$@"\n', encoding="utf-8")
            executable.chmod(0o755)

    def run_step(self, exit_code=0, umask=0o022):
        process = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base), "ARTIFACT_DIR": str(self.artifacts),
            "SHARED_DIR": str(self.shared), "JOB_NAME": "fixture", "BUILD_ID": "1",
            "OCM_FVT_JOB_NAME": "fixture", "FIXTURE_DIR": str(self.base),
            "FIXTURE_EXIT": str(exit_code),
        }, capture_output=True, text=True, timeout=120, umask=umask, check=False)
        # The mirror must never become the thing that decides the step's status.
        self.assertEqual(process.returncode, exit_code, process.stderr)
        self.assertNotIn(SECRET, process.stdout + process.stderr)
        # The OSDFM stage-promotion post step reads this copy.
        self.assertEqual((self.shared / EXIT_CODE_ARTIFACT).read_text().strip(),
                         str(exit_code))
        return process

    def published(self):
        path = self.artifacts / EXIT_CODE_ARTIFACT
        self.assertFalse(path.is_symlink(), "the artifact must not be a symlink")
        contents = path.read_text(encoding="utf-8")
        self.assertTrue(contents.strip().isdigit(), "the artifact holds one integer")
        self.assertEqual(contents.strip(), contents.strip("\n"))
        return path, contents.strip()

    def test_published_copy_matches_the_process_return(self):
        for exit_code in (0, 1, 42, 137):
            with self.subTest(exit_code=exit_code):
                self.setUp()
                self.run_step(exit_code)
                self.assertEqual(self.published()[1], str(exit_code))

    def test_published_copy_is_collector_readable_under_a_restrictive_umask(self):
        """cp takes the mode from the source, which a 0077 umask makes 0600."""
        self.run_step(1, umask=0o077)
        path, value = self.published()
        self.assertEqual(value, "1")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)

    def test_published_copy_replaces_an_existing_symlink(self):
        (self.artifacts / EXIT_CODE_ARTIFACT).symlink_to(self.outside)
        self.run_step(42)
        self.assertEqual(self.published()[1], "42")
        self.assertEqual(self.outside.read_text(), SECRET)

    def test_published_copy_replaces_an_existing_unwritable_file(self):
        existing = self.artifacts / EXIT_CODE_ARTIFACT
        existing.write_text(SECRET, encoding="utf-8")
        existing.chmod(0o400)
        # Restrictive umask too, so the mode assertion below is load-bearing
        # rather than something a 0022 umask would have produced anyway.
        self.run_step(42, umask=0o077)
        path, value = self.published()
        self.assertEqual(value, "42")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)

    @UNPRIVILEGED
    def test_a_failed_mirror_does_not_follow_an_existing_symlink(self):
        """A mirror that cannot be written changes nothing and keeps the return.

        The SHARED_DIR write is best effort, so the source can be absent with a
        link already at the artifact name. cp must refuse, the chmod chained to
        it must not run, and the link's target must keep its own mode and
        content.
        """
        self.outside.chmod(0o600)
        (self.artifacts / EXIT_CODE_ARTIFACT).symlink_to(self.outside)
        self.shared.chmod(0o500)
        self.addCleanup(self.shared.chmod, 0o700)
        process = subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base), "ARTIFACT_DIR": str(self.artifacts),
            "SHARED_DIR": str(self.shared), "JOB_NAME": "fixture", "BUILD_ID": "1",
            "OCM_FVT_JOB_NAME": "fixture", "FIXTURE_DIR": str(self.base),
            "FIXTURE_EXIT": "42",
        }, capture_output=True, text=True, timeout=120, check=False)
        self.assertEqual(process.returncode, 42, process.stderr)
        self.assertFalse((self.shared / EXIT_CODE_ARTIFACT).exists())
        self.assertTrue((self.artifacts / EXIT_CODE_ARTIFACT).is_symlink())
        self.assertEqual(stat.S_IMODE(self.outside.stat().st_mode), 0o600)
        self.assertEqual(self.outside.read_text(), SECRET)

    def test_the_artifact_is_listed_in_the_publication_handoff(self):
        self.run_step(1)
        manifest = json.loads((self.artifacts / AUDIT).read_text(encoding="utf-8"))
        listed = {entry["name"]: entry for entry in manifest["handoff"]["entries"]}
        self.assertIn(EXIT_CODE_ARTIFACT, listed)
        self.assertEqual(listed[EXIT_CODE_ARTIFACT]["state"], "file")
        self.assertEqual(manifest["publication"]["excluded"],
                         {"irregular": 0, "unreadable": 0})
        # Guards against the fixture silently degrading to an empty suite run.
        self.assertIn("junit-ocm-fvt-report.xml", listed)
        self.assertNotIn(SECRET, json.dumps(manifest))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
