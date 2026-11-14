#!/usr/bin/env python3
"""Offline fixtures for the delivered helper: python3 hack/test_rosa_ocm_fvt_failure_summary.py.

The helper source is the one the prepare step delivers, and it is run the way
rosa-e2e-ocm-fvt runs it. Reports are synthetic Ginkgo JSON documents built
here; no private report is used and none is needed, because the summary reads
only state and label metadata. Every test asserts the projection as a whole:
each string in the artifact must belong to a vocabulary fixed in this file, so
a field that ever copied report text would fail every case, not only its own.
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
HELPER = STEP / "prepare/rosa-e2e-ocm-fvt-prepare-commands.py"
RUNNER = STEP / "rosa-e2e-ocm-fvt-commands.sh"
SUMMARY = "ocm-fvt-failure-summary.json"
PHASES = ("pre-env-validation", "pre-vpc-cleaner", "pre-cluster-creation", "post-clean")
# Text a report may carry that the summary must never reproduce.
SECRET = "FIXTURE_SECRET_DO_NOT_PRINT"
HOSTILE = {
    "LeafNodeText": f"creates a cluster with token {SECRET}",
    "ContainerHierarchyTexts": [f"[author:someone] {SECRET}", "https://example.invalid/leak"],
    "LeafNodeLocation": {"FileName": f"/src/tests/{SECRET}_test.go", "LineNumber": 42},
    "Failure": {"Message": f"Expected 200, got 401: {SECRET}",
                "Location": {"FileName": "/src/tests/secret_test.go", "LineNumber": 7},
                "ForwardedPanic": SECRET},
    "CapturedGinkgoWriterOutput": f"Bearer {SECRET}",
    "CapturedStdOutErr": f"cluster 1g268u7pp694gj152nj16me4sv615lpv {SECRET}",
    "StartTime": "2026-11-14T10:15:00.123456789Z",
}
# Every string the summary is allowed to emit, as a key or as a value.
VOCABULARY = set(PHASES) | {
    "schema", "output", "phases", "failures", "limits", "phase", "state", "reports",
    "parsed_reports", "dropped_reports", "specs", "specs_truncated", "failed", "dropped",
    "counts", "identified", "case", "truncated",
    "results", "results_dropped", "results_unreadable", "failures_dropped", "max_failures",
    "scanned", "missing", "irregular", "unreadable", "parsed", "partial", "oversized",
    "malformed", "ambiguous", "unavailable", "unrecognized", "label", "none", "conflicting",
    "pending", "skipped", "passed", "aborted", "panicked", "interrupted", "timedout",
}


def spec(state, labels=(), hierarchy=(), **overrides):
    """Build one synthetic Ginkgo SpecReport carrying hostile text."""
    report = dict(HOSTILE, State=state, LeafNodeLabels=list(labels),
                  ContainerHierarchyLabels=[list(group) for group in hierarchy])
    report.update(overrides)
    return report


def document(*specs):
    """Build the []types.Report document GenerateJSONReport writes."""
    return [{"SuiteDescription": f"OCM FVT {SECRET}", "SuiteSucceeded": False,
             "SuitePath": f"/src/tests/{SECRET}", "SpecReports": list(specs)}]


class SummaryFixture(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)
        self.output = self.base / "output"
        self.output.mkdir()
        self.artifacts = self.base / "artifacts"
        self.artifacts.mkdir()
        self.outside = self.base / "outside"
        self.outside.mkdir()
        (self.outside / "secret").write_text(SECRET, encoding="utf-8")

    def report(self, phase, specs, result="test-result-fixture", index=0, name=None):
        """Write one synthetic per-phase report into a result directory."""
        directory = self.output / result
        directory.mkdir(exist_ok=True)
        path = directory / (name or f"{phase}_{index:06d}.json")
        if isinstance(specs, (str, bytes)):
            mode = "wb" if isinstance(specs, bytes) else "w"
            with path.open(mode) as report:
                report.write(specs)
        else:
            path.write_text(json.dumps(document(*specs)), encoding="utf-8")
        return path

    def run_summary(self, artifact=SUMMARY, output=None, returncode=0):
        result = subprocess.run(
            [sys.executable, "-I", str(HELPER), "summary",
             str(output or self.output), str(self.artifacts / artifact)],
            capture_output=True, text=True, timeout=120, umask=0o022, check=False)
        self.assertEqual(result.returncode, returncode, result.stderr)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def summary(self, artifact=SUMMARY, **arguments):
        self.run_summary(artifact=artifact, **arguments)
        path = self.artifacts / artifact
        # Run under the runner's own umask 022, so the artifact the Prow
        # sidecar collects is the 0644 the helper asks for.
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        self.assertEqual(path.stat().st_uid, os.geteuid())
        contents = path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET, contents)
        self.assertLess(len(contents), 32000)
        data = json.loads(contents)
        self.check_vocabulary(data)
        return data

    def check_vocabulary(self, node):
        """Every string is a fixed term and every number a bounded integer."""
        if isinstance(node, dict):
            for key, value in node.items():
                self.assertIn(key, VOCABULARY)
                self.check_vocabulary(value)
        elif isinstance(node, list):
            for value in node:
                self.check_vocabulary(value)
        elif isinstance(node, str):
            self.assertIn(node, VOCABULARY)
        elif isinstance(node, bool):
            pass
        elif isinstance(node, int):
            self.assertGreaterEqual(node, 0)
            self.assertLessEqual(node, 999999999)
        else:
            raise AssertionError(f"Unexpected summary value type: {type(node)}")

    def phase(self, data, phase):
        return next(record for record in data["phases"] if record["phase"] == phase)


class SummaryProjectionTests(SummaryFixture):
    def test_failed_cases_are_identified_by_label(self):
        self.report("pre-cluster-creation", [
            spec("passed", labels=["id_76488"]),
            spec("failed", labels=["id_12345", "critical", "author:someone"]),
            spec("timedout", hierarchy=[["id_6789"], ["e2e"]]),
        ])
        self.report("post-clean", [spec("panicked", labels=["id_1"])], index=1)
        data = self.summary()
        self.assertEqual(data["output"], "scanned")
        self.assertEqual(data["failures"], [
            {"phase": "pre-cluster-creation", "state": "failed",
             "identified": "label", "case": 12345},
            {"phase": "pre-cluster-creation", "state": "timedout",
             "identified": "label", "case": 6789},
            {"phase": "post-clean", "state": "panicked", "identified": "label", "case": 1},
        ])
        creation = self.phase(data, "pre-cluster-creation")
        self.assertEqual(creation["state"], "parsed")
        self.assertEqual(creation["counts"], {"passed": 1, "failed": 1, "timedout": 1})
        self.assertEqual((creation["specs"], creation["failed"], creation["reports"]), (3, 2, 1))
        self.assertEqual(self.phase(data, "pre-vpc-cleaner")["state"], "unavailable")
        self.assertEqual(self.phase(data, "pre-vpc-cleaner")["counts"], {})

    def test_non_failed_specs_produce_no_records(self):
        self.report("pre-env-validation", [spec(state, labels=["id_42"])
                                           for state in ("passed", "skipped", "pending")])
        data = self.summary()
        self.assertEqual(data["failures"], [])
        record = self.phase(data, "pre-env-validation")
        self.assertEqual(record["counts"], {"passed": 1, "skipped": 1, "pending": 1})
        self.assertEqual(record["failed"], 0)

    def test_hostile_report_text_is_never_copied(self):
        self.report("post-clean", [spec("failed", labels=[f"id_1 {SECRET}", "id_x"])])
        data = self.summary()
        raw = (self.artifacts / SUMMARY).read_text(encoding="utf-8")
        for leaked in ("example.invalid", "author", "_test.go", "Bearer", "2026-11-14",
                       "1g268u7pp694gj152nj16me4sv615lpv", "401"):
            self.assertNotIn(leaked, raw)
        self.assertEqual(data["failures"],
                         [{"phase": "post-clean", "state": "failed", "identified": "none"}])

    def test_non_canonical_identifiers_are_rejected(self):
        rejected = ("id_0", "id_0076488", "id_1234567890", "id_abc", "ID_12",
                    "x id_12", "id_12 ", "id_\u0661\u0662")
        for index, label in enumerate(rejected):
            self.report("post-clean", [spec("failed", labels=[label])],
                        result=f"test-result-{index:02d}")
        data = self.summary()
        self.assertEqual(len(data["failures"]), len(rejected))
        self.assertEqual({record["identified"] for record in data["failures"]}, {"none"})
        self.assertTrue(all("case" not in record for record in data["failures"]))

    def test_non_string_labels_and_states_are_refused(self):
        self.report("post-clean", [
            spec("failed", labels=[True, 76488, ["id_5"], None, "id_7"]),
            spec(True, labels=["id_8"]),
            spec("FAILED", labels=["id_9"]),
            spec(None),
        ])
        data = self.summary()
        self.assertEqual(data["failures"],
                         [{"phase": "post-clean", "state": "failed",
                           "identified": "label", "case": 7}])
        self.assertEqual(self.phase(data, "post-clean")["counts"],
                         {"failed": 1, "unrecognized": 3})

    def test_disagreeing_labels_are_ambiguous(self):
        self.report("post-clean", [spec("aborted", labels=["id_11"], hierarchy=[["id_12"]]),
                                   spec("failed", labels=["id_13"], hierarchy=[["id_13"]])])
        data = self.summary()
        # Sorted by phase, then state: the aborted spec whose labels disagree
        # comes first and names no case, the failed spec whose labels agree
        # carries one.
        self.assertEqual([record["identified"] for record in data["failures"]],
                         ["conflicting", "label"])
        self.assertNotIn("case", data["failures"][0])
        self.assertEqual(data["failures"][1]["case"], 13)


class SummaryFailClosedTests(SummaryFixture):
    def test_missing_and_empty_output(self):
        data = self.summary(output=self.base / "absent")
        self.assertEqual(data["output"], "missing")
        self.assertTrue(all(record["state"] == "unavailable" for record in data["phases"]))
        data = self.summary(artifact="second.json")
        self.assertEqual(data["output"], "scanned")
        self.assertEqual(data["limits"]["results"], 0)

    def test_malformed_truncated_and_undecodable_reports(self):
        whole = json.dumps(document(spec("failed", labels=["id_3"])))
        self.report("pre-env-validation", whole[:len(whole) // 2])
        self.report("pre-vpc-cleaner", b"\xff\xfe not utf-8")
        self.report("pre-cluster-creation", "")
        data = self.summary()
        for phase in ("pre-env-validation", "pre-vpc-cleaner", "pre-cluster-creation"):
            self.assertEqual(self.phase(data, phase)["state"], "malformed")
        self.assertEqual(data["failures"], [])

    def test_unexpected_report_shapes_are_ambiguous(self):
        for index, content in enumerate((
                {"SpecReports": [spec("failed", labels=["id_3"])]},
                [{"SpecReports": {"0": spec("failed")}}],
                [[spec("failed")]],
                [spec("failed", labels=["id_3"])],
                "[]",
        )):
            with self.subTest(index=index):
                self.setUp()
                self.report("post-clean", json.dumps(content))
                data = self.summary()
                self.assertEqual(self.phase(data, "post-clean")["state"], "ambiguous")
                self.assertEqual(data["failures"], [])

    def test_report_without_specs_is_parsed(self):
        self.report("post-clean", json.dumps([{"SuiteSucceeded": True, "SpecReports": None}]))
        data = self.summary()
        record = self.phase(data, "post-clean")
        self.assertEqual((record["state"], record["specs"]), ("parsed", 0))

    def test_oversized_report_is_refused(self):
        padding = "A" * (9 * 1024 * 1024)
        self.report("post-clean", json.dumps(document(spec("failed", labels=["id_3"],
                                                           CapturedStdOutErr=padding))))
        data = self.summary()
        self.assertEqual(self.phase(data, "post-clean")["state"], "oversized")

    def test_phase_mixing_usable_and_unusable_reports_is_partial(self):
        self.report("post-clean", [spec("failed", labels=["id_4"])], index=1)
        self.report("post-clean", "{", index=2)
        data = self.summary()
        record = self.phase(data, "post-clean")
        self.assertEqual((record["state"], record["reports"], record["parsed_reports"]),
                         ("partial", 2, 1))
        self.assertEqual(data["failures"][0]["case"], 4)

    def test_junit_siblings_and_foreign_names_are_not_read(self):
        self.report("post-clean", "<testsuites/>", name="post-clean_000001.xml")
        self.report("post-clean", "<testsuites/>", name="report.xml")
        self.report("post-clean", json.dumps(document(spec("failed"))), name="other.json")
        data = self.summary()
        self.assertEqual(self.phase(data, "post-clean")["state"], "unavailable")
        self.assertEqual(data["limits"]["results"], 1)

    def test_symlinked_output_tree_is_not_followed(self):
        link = self.base / "linked-output"
        link.symlink_to(self.outside, target_is_directory=True)
        self.assertEqual(self.summary(output=link)["output"], "irregular")

    def test_symlinked_results_and_reports_are_not_followed(self):
        self.report("post-clean", [spec("failed", labels=["id_5"])])
        (self.output / "test-result-fixture/pre-clean.json").symlink_to(self.outside / "secret")
        (self.output / "test-result-fixture/post-clean_000009.json").symlink_to(
            self.outside / "secret")
        (self.output / "test-result-linked").symlink_to(self.outside, target_is_directory=True)
        data = self.summary()
        record = self.phase(data, "post-clean")
        self.assertEqual((record["state"], record["reports"], record["parsed_reports"]),
                         ("partial", 2, 1))
        self.assertEqual(data["limits"]["results_unreadable"], 1)
        self.assertEqual((self.outside / "secret").read_text(encoding="utf-8"), SECRET)

    def test_report_name_that_is_a_directory_is_unreadable(self):
        (self.output / "test-result-fixture").mkdir()
        (self.output / "test-result-fixture/post-clean_000001.json").mkdir()
        data = self.summary()
        self.assertEqual(self.phase(data, "post-clean")["state"], "unreadable")

    def test_spec_list_holding_a_non_object_is_ambiguous(self):
        self.report("post-clean", json.dumps(
            [{"SpecReports": [spec("failed", labels=["id_3"]), "not-a-spec"]}]))
        self.assertEqual(self.phase(self.summary(), "post-clean")["state"], "ambiguous")

    def test_report_holding_several_documents_is_folded(self):
        self.report("post-clean", json.dumps(document(spec("failed", labels=["id_3"]))
                                             + document(spec("passed", labels=["id_4"]))))
        data = self.summary()
        self.assertEqual(self.phase(data, "post-clean")["specs"], 2)
        self.assertEqual(data["failures"][0]["case"], 3)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_output_tree_is_recorded(self):
        self.report("post-clean", [spec("failed", labels=["id_11"])])
        self.output.chmod(0)
        self.addCleanup(self.output.chmod, 0o700)
        self.assertEqual(self.summary()["output"], "unreadable")

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_report_is_recorded_not_skipped(self):
        path = self.report("post-clean", [spec("failed", labels=["id_6"])])
        path.chmod(0)
        data = self.summary()
        self.assertEqual(self.phase(data, "post-clean")["state"], "unreadable")

    def test_existing_artifact_is_not_overwritten_or_followed(self):
        self.report("post-clean", [spec("failed", labels=["id_7"])])
        (self.artifacts / SUMMARY).symlink_to(self.outside / "secret")
        self.run_summary(returncode=1)
        self.assertTrue((self.artifacts / SUMMARY).is_symlink())
        self.assertEqual((self.outside / "secret").read_text(encoding="utf-8"), SECRET)


class SummaryBoundsTests(SummaryFixture):
    def test_result_directories_are_bounded(self):
        for index in range(20):
            self.report("post-clean", [spec("passed")], result=f"test-result-{index:02d}")
        data = self.summary()
        self.assertEqual(data["limits"]["results"], 16)
        self.assertEqual(data["limits"]["results_dropped"], 4)
        self.assertTrue(data["limits"]["truncated"])
        self.assertEqual(self.phase(data, "post-clean")["reports"], 16)

    def test_reports_per_phase_are_bounded_without_starving_other_phases(self):
        for index in range(40):
            self.report("post-clean", [spec("failed", labels=["id_900"])], index=index)
        self.report("pre-cluster-creation", [spec("failed", labels=["id_76488"])], index=99)
        data = self.summary()
        teardown = self.phase(data, "post-clean")
        self.assertEqual((teardown["reports"], teardown["dropped_reports"]), (8, 32))
        creation = self.phase(data, "pre-cluster-creation")
        self.assertEqual((creation["state"], creation["reports"]), ("parsed", 1))
        self.assertIn({"phase": "pre-cluster-creation", "state": "failed",
                       "identified": "label", "case": 76488}, data["failures"])

    def test_failure_budget_reaches_the_test_phases_before_teardown(self):
        self.report("post-clean", [spec("failed", labels=[f"id_{900 + index}"])
                                   for index in range(70)])
        self.report("pre-cluster-creation", [spec("failed", labels=["id_76488"])], index=1)
        data = self.summary()
        self.assertEqual(len(data["failures"]), 64)
        self.assertIn({"phase": "pre-cluster-creation", "state": "failed",
                       "identified": "label", "case": 76488}, data["failures"])
        self.assertEqual(self.phase(data, "pre-cluster-creation")["dropped"], 0)
        self.assertEqual(self.phase(data, "post-clean")["dropped"], 7)
        self.assertEqual(data["limits"]["failures_dropped"], 7)

    def test_specs_per_report_are_bounded(self):
        self.report("post-clean", [spec("passed")] * 5000)
        record = self.phase(self.summary(), "post-clean")
        self.assertEqual(record["specs"], 4096)
        self.assertTrue(record["specs_truncated"])

    def test_failure_records_are_bounded_and_counted(self):
        self.report("post-clean", [spec("failed", labels=[f"id_{index + 1}"])
                                   for index in range(100)])
        data = self.summary()
        self.assertEqual(len(data["failures"]), 64)
        self.assertEqual(data["limits"]["failures_dropped"], 36)
        self.assertEqual(data["limits"]["max_failures"], 64)
        self.assertEqual(self.phase(data, "post-clean")["failed"], 100)

    def test_directory_entry_scan_is_bounded(self):
        for index in range(5000):
            (self.output / f"ignored-{index:04d}").touch()
        self.report("post-clean", [spec("passed")], result="test-result-zzz")
        self.assertTrue(self.summary()["limits"]["truncated"])

    def test_unrelated_entries_do_not_hide_a_phase_report(self):
        self.report("post-clean", [spec("failed", labels=["id_8"])])
        for index in range(2000):
            (self.output / "test-result-fixture" / f"ignored-{index:04d}").touch()
        data = self.summary()
        record = self.phase(data, "post-clean")
        self.assertEqual((record["state"], record["reports"]), ("parsed", 1))
        self.assertEqual(data["failures"][0]["case"], 8)
        self.assertEqual(data["limits"]["results"], 1)

    def test_label_budget_is_bounded_per_spec(self):
        padding = [f"label-{index}" for index in range(400)]
        self.report("post-clean", [spec("failed", labels=padding + ["id_9"]),
                                   spec("failed", labels=["id_10"] + padding)])
        data = self.summary()
        # The spec whose id_ label sits past the budget names no case; the one
        # whose id_ label comes first still does.
        self.assertEqual([record["identified"] for record in data["failures"]],
                         ["none", "label"])
        self.assertEqual(data["failures"][1]["case"], 10)


class SummaryIntegrationTests(SummaryFixture):
    def test_runner_summarises_before_publishing(self):
        script = RUNNER.read_text(encoding="utf-8")
        run = script.index("podman run \\")
        summarise = script.index(f'summary "${{ocm_fvt_output}}" "${{ARTIFACT_DIR}}/{SUMMARY}"')
        publish = script.index('publish "${ocm_fvt_output}" "${ARTIFACT_DIR}"')
        self.assertLess(run, summarise)
        self.assertLess(summarise, publish)
        self.assertIn('|| echo "WARNING: failed to summarize ocm-fvt failures"', script)

    def helper(self, *arguments):
        return subprocess.run([sys.executable, "-I", str(HELPER), *arguments],
                              capture_output=True, text=True, timeout=60, check=False)

    def test_summary_survives_publication_and_censoring(self):
        self.report("pre-cluster-creation", [spec("failed", labels=["id_76488"]),
                                             spec("passed", labels=["id_1"])])
        workdir = self.base / "staging"
        workdir.mkdir()
        shutil.copytree(self.output, workdir / "output")
        staged = workdir / "output"
        metadata = self.helper("metadata", str(staged),
                               str(self.artifacts / "ocm-fvt-artifact-metadata.json"))
        self.assertEqual(metadata.returncode, 0, metadata.stderr)
        summary = self.helper("summary", str(staged), str(self.artifacts / SUMMARY))
        self.assertEqual(summary.returncode, 0, summary.stderr)
        published = self.helper("publish", str(staged), str(self.artifacts))
        self.assertEqual(published.returncode, 0, published.stderr)

        audit = json.loads((self.artifacts / "ocm-fvt-artifact-audit.json")
                           .read_text(encoding="utf-8"))
        handoff = {entry["name"]: entry for entry in audit["handoff"]["entries"]}
        self.assertIn(SUMMARY, handoff)
        self.assertEqual(handoff[SUMMARY]["size"], (self.artifacts / SUMMARY).stat().st_size)
        self.assertNotIn(SUMMARY, [record["path"] for record in audit["entries"]])

        self.assertNotIn(SUMMARY, [path.name for path in
                                   (self.artifacts / "ocm-fvt-results").rglob("*")])
        notice = "This file has been removed by the artifact scanner.\n"
        replaced = 0
        for report in (self.artifacts / "ocm-fvt-results").rglob("*.json"):
            report.write_text(notice, encoding="utf-8")
            replaced += 1
        self.assertEqual(replaced, 1)
        data = json.loads((self.artifacts / SUMMARY).read_text(encoding="utf-8"))
        self.check_vocabulary(data)
        self.assertEqual(data["failures"], [{"phase": "pre-cluster-creation", "state": "failed",
                                             "identified": "label", "case": 76488}])


if __name__ == "__main__":
    unittest.main()
