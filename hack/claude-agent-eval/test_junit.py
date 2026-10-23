"""Verify JUnit remains consumable for arbitrary diagnostic text."""

from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

try:
    from .test_manifest_runner import runner
except ImportError:
    from test_manifest_runner import runner


class JunitTests(unittest.TestCase):
    def test_illegal_characters_in_passing_names_and_failures_remain_parseable(self):
        illegal = "".join(chr(code) for code in range(32) if code not in (9, 10, 13))
        illegal += "\ud800\udfff\ufffe\uffff"
        visible = "".join(f"\\u{ord(char):04x}" for char in illegal)
        results = [("passing" + illegal, 1.0, ""), ("failed", 2.0, "error" + illegal)]
        with tempfile.TemporaryDirectory() as directory:
            runner.write_junit(Path(directory), results)
            suite = ET.parse(Path(directory) / "junit_claude-eval.xml").getroot()
        self.assertEqual(suite.attrib["tests"], "2")
        self.assertEqual(suite.attrib["failures"], "1")
        passing, failed = suite.findall("testcase")
        self.assertEqual(passing.attrib["name"], f"[sig-claude] passing{visible} evaluation")
        self.assertIsNone(passing.find("failure"))
        self.assertEqual(failed.find("failure").attrib["message"], "error" + visible)
        self.assertEqual(failed.find("failure").text, "error" + visible)
        self.assertEqual(results[1][2], "error" + illegal)

    def test_valid_unicode_and_xml_metacharacters_are_preserved(self):
        text = '中文 😀 <tag> & "quotes"\t\n\r\u0020\ud7ff\ue000\ufffd\U00010000\U0010ffff'
        with tempfile.TemporaryDirectory() as directory:
            runner.write_junit(Path(directory), [(text, 0.0, text)])
            case = ET.parse(Path(directory) / "junit_claude-eval.xml").getroot().find("testcase")
        self.assertEqual(case.attrib["name"], f"[sig-claude] {text} evaluation")
        self.assertEqual(case.find("failure").attrib["message"], text)
        # XML normalizes literal carriage returns in element text to newlines.
        self.assertEqual(case.find("failure").text, text.replace("\r", "\n"))


if __name__ == "__main__":
    unittest.main()
