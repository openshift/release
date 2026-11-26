#!/usr/bin/env python3
"""Offline tests of result handling and the remote timeout/stop contract.

These execute the actual embedded scripts against temporary files/processes.
They never connect to a host or invoke Ansible/Terraform.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1] / "ci-operator/step-registry/assisted/qe/regression0"


def script(phase):
    return (ROOT / phase / f"assisted-qe-regression0-{phase}-commands.sh").read_text()


def heredoc(text, delimiter):
    match = re.search(r"<<'" + delimiter + r"'[^\n]*\n(.*?)\n" + delimiter + r"\n", text, re.S)
    if not match:
        raise AssertionError(f"Missing {delimiter} heredoc")
    return match.group(1) + "\n"


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.reports = self.work / "reports"
        self.reports.mkdir()

    def verify(self, xml=None, sentinel=False):
        if xml is not None:
            (self.reports / "unittest.xml").write_text(xml)
        if sentinel:
            (self.work / "failed").touch()
        code = heredoc(script("test"), "PY").replace(
            "'/var/tmp/assisted/assisted-test-infra'", repr(str(self.work)))
        return subprocess.run(["python3", "-"], input=code, text=True, capture_output=True)

    def test_successful_results(self):
        result = self.verify('<testsuite tests="1"><testcase name="test_install"/></testsuite>')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failure_sentinel_overrides_passing_xml(self):
        result = self.verify('<testsuite><testcase name="test_install"/></testsuite>', sentinel=True)
        self.assertNotEqual(result.returncode, 0)

    def test_missing_xml_is_failure(self):
        self.assertNotEqual(self.verify().returncode, 0)

    def test_invalid_and_unsuccessful_reports(self):
        reports = [
            'not xml',
            '<testsuite tests="0"/>',
            '<testsuite><testcase name="test_install"><skipped/></testcase></testsuite>',
            '<testsuite><testcase name="test_install"><failure>failed</failure></testcase></testsuite>',
            '<testsuite><testcase name="test_install"><error>error</error></testcase></testsuite>',
            '<testsuite errors="1"><testcase name="test_install"/></testsuite>',
        ]
        for xml in reports:
            with self.subTest(xml=xml):
                self.assertNotEqual(self.verify(xml).returncode, 0)

    def test_public_results_exclude_private_data(self):
        results = self.work / "results"
        results.mkdir()
        (results / "unittest.xml").write_text('''<testsuites><testsuite>
          <properties><property name="token" value="SYNTHETIC_SECRET"/></properties>
          <testcase name="test_install[SYNTHETIC_SECRET]" classname="SYNTHETIC_SECRET">
            <failure message="SYNTHETIC_SECRET">SYNTHETIC_SECRET</failure>
            <system-out>SYNTHETIC_SECRET</system-out>
          </testcase>
          <testcase name="test_network"><skipped message="SYNTHETIC_SECRET"/></testcase>
        </testsuite></testsuites>''')
        (results / "report-portal.log").write_text("SYNTHETIC_SECRET")
        (results / "revisions.txt").write_text("ocp-edge abcdef\n")
        result = subprocess.run(["python3", "-", str(self.work)],
                                input=heredoc(script("gather"), "PY"), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = list((self.work / "public").iterdir())
        self.assertEqual({p.name for p in files}, {"junit_unittest.xml", "revisions.txt"})
        self.assertNotIn("SYNTHETIC_SECRET", "".join(p.read_text() for p in files))
        tree = ET.parse(self.work / "public/junit_unittest.xml")
        self.assertEqual(tree.getroot().get("failures"), "1")
        self.assertEqual(tree.getroot().get("skipped"), "1")

    def test_host_timeout_returns_failure_and_removes_pid(self):
        (self.work / "test.sh").write_text("sleep 30\n")
        result = subprocess.run(["bash", "-s", "--", str(self.work), "test", "0.2s"],
                                input=heredoc(script("setup"), "SUPERVISOR"),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertFalse((self.work / "active.pid").exists())

    def test_post_stops_disconnected_remote_phase(self):
        phase = self.work / "test.sh"
        phase.write_text("sleep 30\n")
        process = subprocess.Popen(["timeout", "60", "bash", str(phase)], start_new_session=True)
        (self.work / "active.pid").write_text(str(process.pid) + "\n")
        try:
            result = subprocess.run(["bash", "-s", "--", str(self.work)],
                                    input='sudo() { shift; command "$@"; }\n' + heredoc(script("setup"), "STOP"),
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNotNone(process.poll())
            self.assertFalse((self.work / "active.pid").exists())
        finally:
            if process.poll() is None:
                os.killpg(process.pid, 9)
            process.wait()

    def test_shell_syntax_including_embedded_scripts(self):
        for phase in ("setup", "provision", "test", "gather", "release"):
            code = script(phase)
            snippets = [code, heredoc(code, "REMOTE")]
            if phase == "setup":
                snippets.extend(heredoc(code, d) for d in ("HELPER", "SUPERVISOR", "STOP", "DEFAULTS", "ENVIRONMENT"))
            if phase == "gather":
                snippets.extend(re.findall(r"<<'REPORT'\n(.*?)\nREPORT\n", code, re.S))
            for snippet in snippets:
                result = subprocess.run(["bash", "-n"], input=snippet, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, f"{phase}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
