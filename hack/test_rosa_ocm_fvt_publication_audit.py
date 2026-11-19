#!/usr/bin/env python3
"""Offline fixtures for the publication audit manifest:

    python3 hack/test_rosa_ocm_fvt_publication_audit.py

The delivered helper is run as the step runs it, as a separate process on a
real directory tree, so the manifest these assertions read is the one the step
would hand to the Prow sidecar. Nothing here contacts a cluster, a registry or
GCS, and no fixture content reaches the manifest.
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
HELPERS = (REPOSITORY / "ci-operator/step-registry/rosa/e2e/ocm-fvt/prepare"
           / "rosa-e2e-ocm-fvt-prepare-commands.py")
AUDIT = "ocm-fvt-artifact-audit.json"
PUBLISHED_DIR = "ocm-fvt-results"
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


if __name__ == "__main__":
    unittest.main()
