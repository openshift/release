#!/usr/bin/env python3
"""Offline tests for the rosa-e2e-capa result summariser.

Run with: python3 hack/test_rosa_capa_result_summary.py

The summariser under test is extracted from the step's own commands script
rather than copied here, so these tests exercise the bytes the step ships. It
is the only writer of the artifact: there is no shell-side placeholder, so a
refusal it cannot record is simply an absent file.

The summary is published to a world readable artifact directory, so the tests
are grouped around the three properties that makes load bearing: the schema is
exactly integers, fixed tokens and generated ordinals; no text from the report
reaches the artifact or the build log; and every refusal is a recorded status
rather than an invented result or a changed exit status.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/rosa/e2e/capa/rosa-e2e-capa-commands.sh"
SUMMARY_NAME = "rosa-hcp-e2e-test-summary.json"
REPORT_DIR = "2026-11-17"
REPORT_NAME = "test-run-provision-20261117_101010.xml"

# Stand-ins for the material the runner's JUnit report really carries: an AWS
# key id, a secret, a token, a cluster hostname, an account id and a local path.
# Every one is planted in a name, a classname, a message, element text or a
# <system-out>, and none may appear in the artifact or on stdout.
SECRETS = (
    "AKIAIOSFODNN7EXAMPLE",
    "wJalrXUtnFEMI-K7MDENG-bPxRfiCYEXAMPLEKEY",
    "sha256~ZmFrZS10b2tlbi12YWx1ZQ",
    "api.ci-abcdef.p1.openshiftapps.com",
    "123456789012",
    "/home/runner/secret-path/kubeconfig",
)

HELPER_PATTERN = re.compile(r"<<'PYTHON_HELPER'\n(.*?)\nPYTHON_HELPER\n", re.S)
# The step must keep running the summariser in isolated mode: the working
# directory at that point is the third-party checkout the step just cloned and
# pip installed into, where a json.py would otherwise shadow a stdlib import.
INVOCATION_PATTERN = re.compile(r'^\s*"\$\{PYTHON\}" -I - ', re.M)


def extract_helper(directory):
    """Write the summariser out of the step script and return its path."""
    found = HELPER_PATTERN.search(STEP.read_text(encoding="utf-8"))
    if not found:
        raise AssertionError(f"the PYTHON_HELPER heredoc is missing from {STEP}")
    helper = Path(directory) / "capa_result_summary.py"
    helper.write_text(found.group(1) + "\n", encoding="utf-8")
    return helper


def junit_document(cases, root="testsuites", suites=1):
    """Build a report shaped like run-test-suite.py's own JUnit output."""
    body = ""
    grouped = [cases[index::suites] for index in range(suites)]
    for group in grouped:
        rendered = ""
        for name, outcome in group:
            inner = ""
            if outcome == "failed":
                inner = (f'<failure type="TestFailure" message="{SECRETS[1]}">'
                         f'Playbook: {SECRETS[5]}</failure>')
            elif outcome == "error":
                inner = (f'<error type="TestError" message="{SECRETS[0]}">'
                         f'{SECRETS[3]}</error>')
            elif outcome == "skipped":
                inner = f'<skipped message="{SECRETS[2]}"/>'
            rendered += (f'<testcase name="{name}" classname="suite {name}" '
                         f'time="1.5">{inner}</testcase>')
        body += (f'<testsuite name="{SECRETS[4]}" timestamp="2026-01-01T00:00:00" '
                 f'tests="{len(group)}" time="1.0">{rendered}'
                 f'<system-out>{SECRETS[2]}</system-out></testsuite>')
    if root == "testsuite":
        return '<?xml version="1.0" ?>' + body
    return (f'<?xml version="1.0" ?><testsuites name="ROSA HCP Test Suite">'
            f'{body}</testsuites>')


class SummaryFixture(unittest.TestCase):
    """Shared fixture: the extracted summariser and a scratch results tree."""

    helper = None
    helper_directory = None

    @classmethod
    def setUpClass(cls):
        cls.helper_directory = tempfile.mkdtemp(prefix="capa-helper-")
        cls.helper = extract_helper(cls.helper_directory)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.helper_directory, ignore_errors=True)

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="capa-case-"))
        self.results = self.base / "test-results"
        self.results.mkdir()
        self.summary = self.base / SUMMARY_NAME

    def write_report(self, text, directory=REPORT_DIR, name=REPORT_NAME):
        """Place one report in a dated directory and return its path."""
        dated = self.results / directory
        dated.mkdir(exist_ok=True)
        report = dated / name
        report.write_text(text, encoding="utf-8")
        return report

    def summarise(self, results=None, summary=None, timeout=120):
        """Run the summariser and return its completed process."""
        return subprocess.run(
            [sys.executable, str(self.helper),
             str(self.results if results is None else results),
             str(self.summary if summary is None else summary)],
            capture_output=True, text=True, check=False, timeout=timeout)

    def published(self):
        """Return the parsed summary artifact."""
        return json.loads(self.summary.read_text(encoding="utf-8"))

    def refuse(self, reason):
        """Assert the summariser recorded the given refusal and still exited 0."""
        completed = self.summarise()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = self.published()
        self.assertEqual(document["status"], "unavailable", document)
        self.assertEqual(document["reason"], reason, document)
        self.assertNotIn("totals", document)
        return document


class SummarySchemaTests(SummaryFixture):
    """The published document is integers, fixed tokens and generated ordinals."""

    def test_totals_and_records_describe_every_outcome(self):
        self.write_report(junit_document(
            [("t1", "passed"), ("t2", "failed"), ("t3", "skipped"),
             ("t4", "error"), ("t5", "passed"), ("t6", "passed")], suites=2))
        completed = self.summarise()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = self.published()
        self.assertEqual(document["status"], "summarized")
        self.assertEqual(document["schema"], 1)
        self.assertEqual(document["suites"], 2)
        self.assertEqual(document["totals"], {
            "tests": 6, "passed": 3, "failed": 1, "errors": 1, "skipped": 1})
        self.assertEqual(document["cases_dropped"], 0)

    def test_records_carry_only_an_ordinal_and_an_outcome(self):
        self.write_report(junit_document([("t1", "passed"), ("t2", "failed")]))
        self.summarise()
        for record in self.published()["cases"]:
            self.assertEqual(set(record), {"id", "suite", "outcome"})
            self.assertRegex(record["id"], r"^case-\d{4}$")
            self.assertRegex(record["suite"], r"^suite-\d{4}$")
            self.assertIn(record["outcome"], ("passed", "failed", "error", "skipped"))

    def test_errored_case_uses_the_singular_outcome_token(self):
        # Regression: the tag-to-counter table once doubled as the published
        # token, so an errored case was reported with the plural "errors".
        self.write_report(junit_document([("t1", "error")]))
        self.summarise()
        document = self.published()
        self.assertEqual(document["cases"][0]["outcome"], "error")
        self.assertEqual(document["totals"]["errors"], 1)

    def test_bare_testsuite_root_is_accepted(self):
        self.write_report(junit_document(
            [("a", "passed"), ("b", "failed")], root="testsuite"))
        self.summarise()
        self.assertEqual(self.published()["totals"]["tests"], 2)

    def test_nested_suite_is_counted_rather_than_dropped(self):
        # Regression: only the root's direct children were walked, so a nested
        # suite's failures vanished and the run was published as all green.
        self.write_report(
            '<?xml version="1.0"?><testsuites><testsuite name="outer">'
            '<testsuite name="inner">'
            '<testcase name="a"><failure message="x">y</failure></testcase>'
            '<testcase name="b"/></testsuite></testsuite></testsuites>')
        self.summarise()
        document = self.published()
        self.assertEqual(document["status"], "summarized")
        self.assertEqual(document["totals"]["tests"], 2)
        self.assertEqual(document["totals"]["failed"], 1)

    def test_record_cap_keeps_the_totals_complete(self):
        self.write_report('<testsuites><testsuite>'
                          + '<testcase name="t"/>' * 1500
                          + '</testsuite></testsuites>')
        self.summarise()
        document = self.published()
        self.assertEqual(document["totals"]["tests"], 1500)
        self.assertEqual(len(document["cases"]), 1000)
        self.assertEqual(document["cases_dropped"], 500)


class SummaryPrivacyTests(SummaryFixture):
    """No text from the report reaches the artifact or the build log."""

    HOSTILE = (
        f'<?xml version="1.0"?><testsuites name="{SECRETS[0]}">'
        f'<testsuite name="{SECRETS[1]}" timestamp="{SECRETS[2]}">'
        f'<properties><property name="token" value="{SECRETS[3]}"/></properties>'
        f'<testcase name="{SECRETS[4]}" classname="{SECRETS[5]}" time="9.9">'
        f'<failure type="T" message="{SECRETS[0]}">{SECRETS[1]}</failure>'
        f'<system-err>{SECRETS[2]}</system-err></testcase>'
        f'<testcase name="ok"><unknown-child>{SECRETS[3]}</unknown-child></testcase>'
        f'<system-out>{SECRETS[4]}</system-out></testsuite></testsuites>')

    def assert_no_secret(self, blob):
        """Assert none of the planted values survived into the given text."""
        for secret in SECRETS:
            self.assertNotIn(secret, blob)

    def test_hostile_report_publishes_outcomes_without_its_text(self):
        self.write_report(self.HOSTILE)
        completed = self.summarise()
        document = self.published()
        self.assertEqual(document["status"], "summarized")
        self.assertEqual(document["totals"], {
            "tests": 2, "passed": 1, "failed": 1, "errors": 0, "skipped": 0})
        self.assert_no_secret(self.summary.read_text(encoding="utf-8"))
        self.assert_no_secret(completed.stdout + completed.stderr)

    def test_console_output_is_counts_only(self):
        self.write_report(junit_document([("t1", "passed"), ("t2", "failed")]))
        completed = self.summarise()
        self.assertEqual(
            completed.stdout.strip(),
            "Structured results: 2 tests, 1 passed, 1 failed, 0 errors, 0 skipped")

    def test_refusal_names_a_token_rather_than_a_path(self):
        completed = self.summarise(results=self.base / "absent")
        self.assertTrue(completed.stdout.startswith("WARNING: "), completed.stdout)
        self.assertNotIn(str(self.base), completed.stdout + completed.stderr)

    def test_summariser_reads_no_credential_or_environment(self):
        body = self.helper.read_text(encoding="utf-8")
        self.assertNotRegex(body, r"/var/run|ocmClient|aws_secret|KUBECONFIG")
        self.assertNotIn("os.environ", body)
        self.assertNotIn("os.getenv", body)


class SummaryStatusBoundaryTests(SummaryFixture):
    """Every refusal is a recorded status, never an invented or partial result."""

    def test_missing_results_directory(self):
        self.results.rmdir()
        self.refuse("no-results-directory")

    def test_empty_results_directory(self):
        self.refuse("no-report")

    def test_more_than_one_report_is_not_guessed_between(self):
        self.write_report(junit_document([("a", "passed")]))
        self.write_report(junit_document([("b", "failed")]), directory="2026-11-18",
                          name="test-run-provision-20261118_101010.xml")
        self.assertEqual(self.refuse("ambiguous-report")["reports_seen"], 2)

    def test_malformed_xml(self):
        self.write_report("<testsuites><testsuite><testcase></testsuites>")
        self.refuse("malformed-report")

    def test_unexpected_root_element(self):
        self.write_report('<?xml version="1.0"?><report><testcase name="x"/></report>')
        self.refuse("unexpected-root")

    def test_document_without_any_testsuite(self):
        # Regression: an empty <testsuites/> was published as "summarized" with
        # zero tests, asserting success on a structurally unusable report.
        self.write_report('<?xml version="1.0"?><testsuites name="x"/>')
        self.refuse("no-testsuites")

    def test_declared_entities_are_refused_rather_than_expanded(self):
        self.write_report(
            '<?xml version="1.0"?><!DOCTYPE t [<!ENTITY a "aaaaaaaaaa">'
            '<!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>'
            '<testsuites><testsuite><testcase name="&b;"/></testsuite></testsuites>')
        self.refuse("doctype-rejected")

    def test_utf16_entity_bomb_cannot_slip_past_the_doctype_guard(self):
        # Regression: the doctype guard is a byte scan, so a UTF-16 document
        # carried an internal subset straight past it into the parser.
        bomb = ('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE t ['
                '<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>'
                '<testsuites><testsuite><testcase name="&b;"/></testsuite></testsuites>')
        self.write_report("").write_bytes(b"\xff\xfe" + bomb.encode("utf-16-le"))
        self.refuse("unsupported-encoding")

    def test_utf8_byte_order_mark_is_tolerated(self):
        self.write_report("").write_bytes(
            b"\xef\xbb\xbf" + junit_document([("a", "passed")]).encode("utf-8"))
        self.summarise()
        self.assertEqual(self.published()["totals"]["tests"], 1)

    def test_oversized_report(self):
        padded = '<testcase name="' + "x" * 1000 + '"/>'
        self.write_report('<testsuites><testsuite>' + padded * 9000
                          + '</testsuite></testsuites>')
        self.refuse("oversized-report")

    def test_more_testcases_than_the_parse_cap(self):
        self.write_report('<testsuites><testsuite>'
                          + '<testcase name="t"/>' * 5001
                          + '</testsuite></testsuites>')
        self.refuse("report-too-large")

    def test_symlinked_report_is_not_followed(self):
        outside = self.base / "outside.xml"
        outside.write_text(junit_document([("a", "passed")]), encoding="utf-8")
        dated = self.results / REPORT_DIR
        dated.mkdir()
        os.symlink(str(outside), str(dated / REPORT_NAME))
        self.refuse("no-report")

    def test_symlinked_dated_directory_is_not_followed(self):
        elsewhere = self.base / "elsewhere" / REPORT_DIR
        elsewhere.mkdir(parents=True)
        (elsewhere / REPORT_NAME).write_text(
            junit_document([("a", "passed")]), encoding="utf-8")
        os.symlink(str(elsewhere), str(self.results / REPORT_DIR))
        self.refuse("no-report")

    def test_fifo_is_rejected_by_the_directory_scan(self):
        dated = self.results / REPORT_DIR
        dated.mkdir()
        os.mkfifo(str(dated / REPORT_NAME))
        completed = self.summarise(timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.refuse("no-report")

    def test_reading_a_fifo_report_does_not_block(self):
        # Regression: read_report opened without O_NONBLOCK, so a fifo with no
        # writer parked the step until its four hour timeout. The scan above
        # keeps a statically planted fifo away from this open, so the second
        # layer is driven directly - a fifo that replaced the report after the
        # scan is the case the flag exists for. Without O_NONBLOCK this call
        # never returns and the timeout fails the test.
        dated = self.results / REPORT_DIR
        dated.mkdir()
        os.mkfifo(str(dated / REPORT_NAME))
        driver = (
            "import importlib.util, sys\n"
            f"spec = importlib.util.spec_from_file_location('h', {str(self.helper)!r})\n"
            "module = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(module)\n"
            "try:\n"
            f"    module.read_report({str(self.results)!r}, {REPORT_DIR!r}, {REPORT_NAME!r})\n"
            "except module.Unavailable as refusal:\n"
            "    print(refusal.reason)\n")
        completed = subprocess.run([sys.executable, "-I", "-c", driver],
                                   capture_output=True, text=True, check=False,
                                   timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "irregular-report")

    def test_the_step_runs_the_summariser_in_isolated_mode(self):
        self.assertRegex(STEP.read_text(encoding="utf-8"), INVOCATION_PATTERN)

    def test_symlinked_destination_is_not_written_through(self):
        self.write_report(junit_document([("a", "passed")]))
        target = self.base / "victim.json"
        target.write_text("ORIGINAL", encoding="utf-8")
        os.symlink(str(target), str(self.summary))
        completed = self.summarise()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "ORIGINAL")
        self.assertIn("WARNING", completed.stdout)

    def test_a_truncated_write_leaves_no_artifact_behind(self):
        # Regression: a write that failed part way left half a JSON document,
        # which the step's fallback check then accepted as a published summary.
        self.write_report(junit_document([(f"t{n}", "passed") for n in range(1200)]))
        # A hard file-size limit makes the write fail after several flushes,
        # which is how a full artifact directory would truncate it in CI.
        completed = subprocess.run(
            ["bash", "-c", f"ulimit -f 20; exec {sys.executable} {self.helper} "
                           f"{self.results} {self.summary}"],
            capture_output=True, text=True, check=False, timeout=120)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertFalse(self.summary.exists())
        self.assertIn("WARNING", completed.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
