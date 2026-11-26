#!/usr/bin/env python3
"""Offline tests of the remote timeout, stop and credential cleanup contract.

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


ROOT = Path(__file__).resolve().parents[1] / "ci-operator/step-registry/assisted/qe"


def script(phase):
    name = phase.replace('/', '-')
    return (ROOT / phase / f"assisted-qe-{name}-commands.sh").read_text()


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
        for path in ROOT.rglob('*-commands.sh'):
            code = path.read_text()
            snippets = [code]
            for marker in ("HELPER", "REMOTE", "SUPERVISOR", "STOP", "ENVIRONMENT"):
                snippets.extend(re.findall(r"<<'" + marker + r"'[^\n]*\n(.*?)\n" + marker + r"\n", code, re.S))
            for snippet in snippets:
                result = subprocess.run(["bash", "-n"], input=snippet, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, f"{path}: {result.stderr}")

    def result_helpers(self):
        namespace = {'__name__': 'test_helpers'}
        exec(heredoc(script('setup'), 'PYTHON'), namespace)
        (self.work / 'results').mkdir(exist_ok=True)
        return namespace

    def test_results_require_executed_passing_tests(self):
        check = self.result_helpers()['check']
        with self.assertRaisesRegex(ValueError, 'No JUnit'):
            check(self.work)
        report = self.work / 'results/test.xml'
        report.write_text('<testsuite><testcase/></testsuite>')
        check(self.work)
        for xml in ('invalid', '<testsuite/>', '<testsuite><testcase><skipped/></testcase></testsuite>',
                    '<testsuite><testcase><failure/></testcase></testsuite>',
                    '<testsuite errors="1"><testcase/></testsuite>'):
            report.write_text(xml)
            with self.subTest(xml=xml), self.assertRaises((ValueError, ET.ParseError)):
                check(self.work)

    def test_failure_marker_overrides_success(self):
        check = self.result_helpers()['check']
        (self.work / 'results/test.xml').write_text('<testsuite><testcase/></testsuite>')
        (self.work / 'results/failed').touch()
        with self.assertRaisesRegex(ValueError, 'failure marker'):
            check(self.work)

    def test_public_results_strip_private_content(self):
        publish = self.result_helpers()['publish']
        (self.work / 'results/test.xml').write_text('''<testsuite><properties><property value="PRIVATE"/></properties>
          <testcase name="test[PRIVATE]" classname="PRIVATE"><failure message="PRIVATE">PRIVATE</failure>
          <system-out>PRIVATE</system-out></testcase></testsuite>''')
        (self.work / 'public').mkdir()
        (self.work / 'public/private.log').write_text('PRIVATE')
        publish(self.work)
        report = self.work / 'public/junit_0.xml'
        self.assertNotIn('PRIVATE', report.read_text())
        self.assertEqual(ET.parse(report).getroot().get('failures'), '1')
        self.assertEqual(list((self.work / 'public').iterdir()), [report])

    def test_scenario_environment_preserves_prow_parameters(self):
        code = heredoc(script('saas/api/prepare'), 'ENVIRONMENT')
        result = subprocess.run(['bash', '-euo', 'pipefail', '-s'], text=True, capture_output=True,
            env=dict(os.environ, WORKSPACE=str(self.work), HOST='example.lab', QE_OCP_VERSION='5.0',
                     QE_SECRETS_DIR=str(self.work / 'secrets'), ASSISTED_TEST_INFRA_MARKER='smoke',
                     ASSISTED_FUNCTIONAL_API_TESTS_PARALLEL='2', MASTER_DISK_SIZE='150'),
            input='rpm() { printf "9"; }\ncat() { printf "fixture-public-key"; }\n' + code +
                  '\nprintf "%s|%s|%s|%s|%s|%s" "$ASSISTED_TEST_INFRA_MARKER" '
                  '"$ASSISTED_FUNCTIONAL_API_TESTS_PARALLEL" "$MASTER_DISK_SIZE" '
                  '"$OCP_MAJOR_VERSION" "$OCP_MINOR_VERSION" "$CLUSTER_NAME"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'smoke|2|150|5|0|example')

    def test_parameter_transport_quotes_values_and_rejects_reserved_names(self):
        (self.work / 'qe-workspace').write_text('/home/test/prow-assisted-qe/run.abcdefgh')
        code = heredoc(script('setup'), 'HELPER')
        function = code[code.index('qe_export() {'):code.index('qe_remote() {')]
        value = 'literal $(false); with spaces and "quotes"'
        env = dict(os.environ, SHARED_DIR=str(self.work), PROFILE_NAME=value)
        result = subprocess.run(['bash', '-euo', 'pipefail', '-s'], text=True, capture_output=True, env=env,
            input='qe_ssh() { cat > "$SHARED_DIR/transport.env"; }\n' + function +
                  '\nqe_export PROFILE_NAME\nsource "$SHARED_DIR/transport.env"\nprintf "%s" "$PROFILE_NAME"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, value)
        result = subprocess.run(['bash', '-euo', 'pipefail', '-s'], text=True, capture_output=True, env=env,
            input='qe_ssh() { exit 99; }\n' + function + '\nqe_export WORKSPACE\n')
        self.assertEqual(result.returncode, 1)

    def test_release_removes_credentials_even_if_archiving_fails(self):
        (self.work / 'secrets').mkdir()
        (self.work / 'secrets/vault').write_text('fixture')
        (self.work / 'job.env').write_text('fixture')
        (self.work / 'logs').mkdir()
        (self.work / 'logs/test.log').write_text('fixture')
        blocks = re.findall(r"<<'REMOTE'[^\n]*\n(.*?)\nREMOTE\n", script('release'), re.S)
        # Redirect only the archive path to this test's temp directory. The real
        # cleanup trap runs, while sudo/copy failure is simulated without privilege.
        archive = str(Path(self.tmp.name) / 'archive')
        code = blocks[-1].replace('archive="$HOME/prow-assisted-qe/artifacts/${work##*/}"',
                                  'archive=' + archive)
        result = subprocess.run(['bash', '-s', '--', str(self.work)],
                                input='sudo() { return 1; }\n' + code, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.work.exists())


if __name__ == "__main__":
    unittest.main()
