"""Offline behavioral tests for the scoped ACS required-resource patch."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = None


class RequiredResources(unittest.TestCase):
    def run_full_script(self, scenario):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mock = root / "oc"
            mock.write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
kind = args[1]
state = Path(os.environ['ACS_STATE'])
scenario = os.environ['ACS_FIXTURE']
if args[0] == 'patch':
    if kind == 'subscription':
        state.write_text('upgraded')
    print('patched')
elif kind == 'subscription':
    selector = args[-1]
    if 'currentCSV' in selector:
        print('rhacs-new' if state.exists() else 'rhacs-old')
    elif 'spec.channel' in selector:
        print('rhacs-4.10')
    elif 'installPlanRef' in selector:
        print('plan-new' if state.exists() else 'plan-old')
    else:
        sys.exit(2)
elif kind == 'installplan':
    print('Automatic' if 'approval' in args[-1] else 'Complete')
elif kind == 'csv':
    if 'spec.version' in args[-1]:
        print('4.11.4' if args[2] == 'rhacs-new' else '4.10.9')
    else:
        print('Succeeded')
elif kind in ('central', 'securedcluster'):
    if '-A' in args:
        if scenario == 'denied-' + kind:
            print('Forbidden', file=sys.stderr)
            sys.exit(1)
        if scenario != 'absent-' + kind:
            print('stackrox')
    else:
        print('True')
elif kind == 'deployment':
    print('True')
elif kind == 'pods':
    print('scanner-0 1/1 Running')
else:
    sys.exit(2)
''')
            mock.chmod(0o700)
            sleep = root / 'sleep'
            sleep.write_text('#!/bin/bash\nexit 0\n')
            sleep.chmod(0o700)
            artifact = root / 'artifacts'
            shared = root / 'shared'
            shared.mkdir()
            script = root / 'acs-fixture.sh'
            script.write_text(SCRIPT.read_text())
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       ACS_FIXTURE=scenario, ACS_STATE=str(root / 'upgraded'),
                       ACS_TARGET_CHANNEL='rhacs-4.11', ARTIFACT_DIR=str(artifact),
                       SHARED_DIR=str(shared))
            result = subprocess.run(['bash', str(script)], env=env, capture_output=True,
                                    text=True, timeout=10, check=False)
            junit = ET.parse(artifact / 'junit_lp-interop--OPP--acs-upgrade.xml').getroot()
            shared_junit = ET.parse(shared / 'junit/junit_lp-interop--OPP--acs-upgrade.xml').getroot()
            return (result, junit, shared_junit,
                    (artifact / 'acs-upgrade-summary.txt').exists(),
                    (shared / 'acs-upgraded-version').exists(),
                    (artifact / 'junit_known_issues.xml').exists())

    def test_full_script_healthy_exit_and_junit(self):
        result, junit, shared, summary, version, skipped = self.run_full_script('healthy')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(junit.get('failures'), '0')
        self.assertEqual(shared.get('failures'), '0')
        self.assertTrue(summary)
        self.assertTrue(version)
        self.assertFalse(skipped)

    def assert_full_failure(self, scenario):
        result, junit, shared, summary, version, skipped = self.run_full_script(scenario)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(junit.get('failures'), '1')
        self.assertIsNotNone(junit.find('.//failure'))
        self.assertEqual(shared.get('failures'), '1')
        self.assertFalse(summary)
        self.assertFalse(version)
        self.assertFalse(skipped)
        self.assertNotIn('=== ACS Operator Upgrade: SUCCESS ===', result.stdout)

    def test_full_script_absent_central(self):
        self.assert_full_failure('absent-central')

    def test_full_script_absent_securedcluster(self):
        self.assert_full_failure('absent-securedcluster')

    def test_full_script_central_discovery_error(self):
        self.assert_full_failure('denied-central')

    def test_full_script_securedcluster_discovery_error(self):
        self.assert_full_failure('denied-securedcluster')

    def validate(self, scenario):
        source = SCRIPT.read_text()
        body = source.split("function ValidateAcsHealth () {", 1)[1].split("# _xml_escape:", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            mock = root / "oc"
            mock.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
kind = args[1]
scenario = os.environ['ACS_FIXTURE']
if '-A' in args:
    if scenario == 'denied-' + kind:
        print('Forbidden', file=sys.stderr)
        sys.exit(1)
    if scenario != 'absent-' + kind:
        print('stackrox')
elif kind in ('central', 'securedcluster', 'deployment'):
    print('True')
elif kind == 'pods':
    print('scanner-0 1/1 Running')
else:
    sys.exit(2)
''')
            mock.chmod(0o700)
            function = root / "validate.sh"
            # Main invokes health validation in a conditional: reproduce that
            # context so explicit returns, rather than errexit, determine failure.
            function.write_text('set -euo pipefail\nfunction ValidateAcsHealth () {' + body +
                                '\nif ValidateAcsHealth; then exit 0; else exit $?; fi\n')
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], ACS_FIXTURE=scenario)
            return subprocess.run(['bash', str(function)], env=env, capture_output=True, text=True, timeout=10, check=False)

    def test_healthy_required_resources(self):
        result = self.validate('healthy')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ACS health validation complete', result.stdout)

    def test_absent_central(self):
        result = self.validate('absent-central')
        self.assertEqual(result.returncode, 1)
        self.assertIn('No required Central CR found', result.stderr)
        self.assertNotIn('ACS health validation complete', result.stdout)

    def test_absent_securedcluster(self):
        result = self.validate('absent-securedcluster')
        self.assertEqual(result.returncode, 1)
        self.assertIn('No required SecuredCluster CR found', result.stderr)
        self.assertNotIn('ACS health validation complete', result.stdout)

    def test_central_discovery_error(self):
        result = self.validate('denied-central')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Unable to query required Central CR', result.stderr)
        self.assertNotIn('No required Central CR found', result.stderr)

    def test_securedcluster_discovery_error(self):
        result = self.validate('denied-securedcluster')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Unable to query required SecuredCluster CR', result.stderr)
        self.assertNotIn('No required SecuredCluster CR found', result.stderr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--script', required=True, type=Path)
    args, rest = parser.parse_known_args()
    SCRIPT = args.script.resolve(strict=True)
    unittest.main(argv=['test_acs_required_resources.py', *rest])
