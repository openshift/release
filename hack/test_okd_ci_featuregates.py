#!/usr/bin/env python3

import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import call, patch

import yaml


ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / 'ci-operator/step-registry'
STEP = REGISTRY / 'openshift/featuregates/okd-ci'
COMMAND = STEP / 'openshift-featuregates-okd-ci-commands.sh'
SOURCE = COMMAND.read_text().split("<<'PYTHON'\n", 1)[1].split('\nPYTHON', 1)[0]
with tempfile.TemporaryDirectory() as helper_directory:
    helper_path = Path(helper_directory) / 'helper.py'
    helper_path.write_text(SOURCE)
    NAMESPACE = runpy.run_path(str(helper_path))
NAMESPACE = NAMESPACE['prepare'].__globals__
HELPER = types.SimpleNamespace(**NAMESPACE)
CI_VERSION = '5.0.0-0.okd-scos-2026-10-23-035130'
NIGHTLY_VERSION = '5.0.0-0.okd-scos-nightly-2026-10-23-035130'


class FeatureGateFixtures(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        self.catalog = self.directory / 'catalog'
        self.catalog.mkdir()
        self.shared = self.directory / 'shared'
        self.shared.mkdir()
        self.config = self.shared / 'install-config.yaml'
        self.config.write_text('featureSet: TechPreviewNoUpgrade\nfeatureGates: [Preview=false]\n')
        self.helper = self.directory / 'helper.py'
        self.helper.write_text(SOURCE)
        NAMESPACE['__file__'] = str(self.helper)
        self.environment = {
            'RELEASE_IMAGE_LATEST': 'target',
            'OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE': 'initial',
            'SHARED_DIR': str(self.shared),
            'CLUSTER_PROFILE_DIR': str(self.directory),
        }

    def write_catalog(self, name='Default', enabled=None, disabled=None, **options):
        path = self.catalog / ('0000_featureGate-' + name + '.yaml')
        path.write_text(yaml.safe_dump({
            'apiVersion': 'config.openshift.io/v1', 'kind': 'FeatureGate',
            'metadata': {'annotations': options.get('annotations')}, 'spec': {'featureSet': name},
            'status': {'featureGates': [{'version': options.get('version', ''),
                                       'enabled': [{'name': gate} for gate in enabled] if enabled else None,
                                       'disabled': [{'name': gate} for gate in disabled] if disabled else None}]},
        }))
        return path

    def default_catalog(self):
        self.write_catalog(enabled=['Baseline'], disabled=['Disabled', 'Preview'])
        self.write_catalog('TechPreviewNoUpgrade', enabled=['Baseline', 'Preview'],
                           disabled=['Disabled', 'ExtraKnown'])

    def prepare(self, target=CI_VERSION, initial='4.22.0-0.nightly-2026-10-22-000000',
                **environment):
        self.default_catalog()
        lookups = []
        extracts = []

        def release_info(image):
            lookups.append(image)
            return {'metadata': {'version': target if image == 'target' else initial}}

        def extract(arguments, **_kwargs):
            extracts.append(arguments)
            destination = Path(next(arg[5:] for arg in arguments if arg.startswith('--to=')))
            shutil.copytree(self.catalog, destination, dirs_exist_ok=True)

        with patch.dict(os.environ, {**self.environment, **environment}, clear=True), \
                patch.dict(NAMESPACE, {'release_info': release_info}), \
                patch.object(HELPER.subprocess, 'run', side_effect=extract):
            HELPER.prepare()
        return lookups, extracts

    def selection(self):
        return json.loads((self.shared / 'okd-ci-featuregates/selection.json').read_text())


class CatalogTests(FeatureGateFixtures):
    def test_complete_catalog_including_nondefault_names(self):
        self.default_catalog()
        known = HELPER.catalog_gates(self.catalog, CI_VERSION)
        self.assertEqual(known, {'Baseline', 'Disabled', 'Preview', 'ExtraKnown'})
        self.assertEqual(known, HELPER.catalog_gates(self.catalog, '4.15.0'))
        self.assertFalse((self.catalog / 'image-references').exists())

    def test_missing_catalog_has_clear_error(self):
        for version in ['4.13.0-0.okd-2023-10-28-065448', CI_VERSION]:
            with self.subTest(version=version), self.assertRaisesRegex(
                    ValueError, 'Missing or incompatible FeatureGate catalogs.*' + version):
                HELPER.catalog_gates(self.catalog, version)


    def test_profile_major_and_version(self):
        for annotations, version, included in [
                (None, '', True),
                ({HELPER.PROFILE: 'false-except-for-the-config-operator',
                  'release.openshift.io/major-version': '4,5,6'}, CI_VERSION, True),
                ({'include.release.openshift.io/ibm-cloud-managed': 'false-except-for-the-config-operator'}, '', False),
                ({HELPER.PROFILE: 'false-except-for-the-config-operator',
                  'release.openshift.io/major-version': '4'}, '', False)]:
            with self.subTest(annotations=annotations, version=version):
                self.write_catalog(enabled=['Baseline'], annotations=annotations, version=version)
                if included:
                    self.assertEqual(HELPER.catalog_gates(self.catalog, CI_VERSION), {'Baseline'})
                else:
                    with self.assertRaisesRegex(ValueError, 'Missing or incompatible'):
                        HELPER.catalog_gates(self.catalog, CI_VERSION)

    def test_null_disabled_and_enabled(self):
        self.write_catalog(enabled=['Baseline'])
        self.write_catalog('TechPreviewNoUpgrade', disabled=['Other'])
        self.assertEqual(HELPER.catalog_gates(self.catalog, CI_VERSION),
                         {'Baseline', 'Other'})

    def test_invalid_catalogs_fail_closed(self):
        for enabled, disabled, version in [(['Same'], ['Same'], ''),
                                           (['AllAlpha'], [], ''),
                                           (['AllBeta'], [], ''),
                                           ([], [], ''),
                                           (['Baseline'], [], 'wrong-version')]:
            with self.subTest(enabled=enabled, disabled=disabled, version=version):
                self.write_catalog(enabled=enabled, disabled=disabled, version=version)
                with self.assertRaises(ValueError):
                    HELPER.catalog_gates(self.catalog, CI_VERSION)

    def test_duplicate_defaults_fail_closed(self):
        path = self.write_catalog(enabled=['Baseline'])
        shutil.copyfile(path, self.catalog / '0001_featureGate-Default.yaml')
        with self.assertRaises(ValueError):
            HELPER.catalog_gates(self.catalog, CI_VERSION)

    def test_empty_default_cannot_be_masked_by_other_sets(self):
        self.write_catalog()
        self.write_catalog('TechPreviewNoUpgrade', enabled=['Other'])
        with self.assertRaisesRegex(ValueError, 'Empty Default FeatureGate catalog'):
            HELPER.catalog_gates(self.catalog, CI_VERSION)


class RetryTests(FeatureGateFixtures):
    def copy_catalog(self, arguments, **options):
        self.assertEqual(options, {'check': True, 'timeout': 600})
        destination = Path(next(arg[5:] for arg in arguments if arg.startswith('--to=')))
        shutil.copytree(self.catalog, destination, dirs_exist_ok=True)

    def test_release_info_retries_transient_failures_then_success(self):
        for image in ['target', 'initial']:
            with self.subTest(image=image), \
                    patch.dict(os.environ, self.environment, clear=True), \
                    patch.object(HELPER.subprocess, 'check_output', side_effect=[
                        subprocess.CalledProcessError(1, 'oc'), subprocess.TimeoutExpired('oc', 120),
                        json.dumps({'metadata': {'version': CI_VERSION}})]) as lookup, \
                    patch.object(HELPER.time, 'sleep') as sleep:
                self.assertEqual(HELPER.release_info(image)['metadata']['version'], CI_VERSION)
                self.assertEqual(lookup.call_count, 3)
                for invocation in lookup.call_args_list:
                    self.assertIn(image, invocation.args[0])
                    self.assertEqual(invocation.kwargs, {'text': True, 'timeout': 120})
                self.assertEqual(sleep.call_args_list, [call(1), call(2)])

    def test_release_info_exhaustion_preserves_shared_settings(self):
        before = self.config.read_bytes()
        for error in [subprocess.TimeoutExpired('oc', 120), subprocess.CalledProcessError(1, 'oc')]:
            with self.subTest(error=type(error).__name__), \
                    patch.dict(os.environ, self.environment, clear=True), \
                    patch.object(HELPER.subprocess, 'check_output', side_effect=error) as lookup, \
                    patch.object(HELPER.subprocess, 'run') as extract, \
                    patch.object(HELPER.time, 'sleep') as sleep:
                with self.assertRaises(type(error)):
                    HELPER.prepare()
                self.assertEqual(lookup.call_count, 3)
                extract.assert_not_called()
                self.assertEqual(sleep.call_args_list, [call(1), call(2)])
                self.assertEqual(self.config.read_bytes(), before)
                self.assertEqual(list(self.shared.iterdir()), [self.config])

    def test_malformed_metadata_is_not_retried(self):
        for output, error in [('not-json', json.JSONDecodeError), ('{}', KeyError)]:
            with self.subTest(output=output), \
                    patch.dict(os.environ, self.environment, clear=True), \
                    patch.object(HELPER.subprocess, 'check_output', return_value=output) as lookup, \
                    patch.object(HELPER.subprocess, 'run') as extract, \
                    patch.object(HELPER.time, 'sleep') as sleep:
                with self.assertRaises(error):
                    HELPER.prepare()
                lookup.assert_called_once()
                extract.assert_not_called()
                sleep.assert_not_called()
                self.assertEqual(list(self.shared.iterdir()), [self.config])

    def test_non_target_retry_success_does_not_extract_or_mutate(self):
        before = self.config.read_bytes()
        for version in [NIGHTLY_VERSION, '4.22.0-0.nightly-2026-10-23-000000', '4.13.42']:
            with self.subTest(version=version), \
                    patch.dict(os.environ, self.environment, clear=True), \
                    patch.object(HELPER.subprocess, 'check_output', side_effect=[
                        subprocess.CalledProcessError(1, 'oc'),
                        json.dumps({'metadata': {'version': version}})]) as lookup, \
                    patch.object(HELPER.subprocess, 'run') as extract, \
                    patch.object(HELPER.time, 'sleep') as sleep:
                HELPER.prepare()
                self.assertEqual(lookup.call_count, 2)
                extract.assert_not_called()
                sleep.assert_called_once_with(1)
                self.assertEqual(self.config.read_bytes(), before)
                self.assertEqual(list(self.shared.iterdir()), [self.config])

    def test_extraction_retries_use_fresh_cleaned_directories(self):
        self.default_catalog()
        directories = []

        def extract(arguments, **options):
            self.assertEqual(options, {'check': True, 'timeout': 600})
            destination = Path(next(arg[5:] for arg in arguments if arg.startswith('--to=')))
            self.assertFalse(list(destination.iterdir()))
            self.assertTrue(all(not previous.exists() for previous in directories))
            directories.append(destination)
            if len(directories) == 1:
                (destination / 'partial-featureGate-stale.yaml').write_text('incomplete')
                raise subprocess.CalledProcessError(1, arguments)
            self.copy_catalog(arguments, **options)

        with patch.dict(os.environ, self.environment, clear=True), \
                patch.object(HELPER.subprocess, 'run', side_effect=extract), \
                patch.object(HELPER.time, 'sleep') as sleep:
            known = HELPER.extract_payload_gates('initial', CI_VERSION)
        self.assertEqual(known, {'Baseline', 'Disabled', 'Preview', 'ExtraKnown'})
        self.assertEqual(len(set(directories)), 2)
        self.assertTrue(all(not directory.exists() for directory in directories))
        sleep.assert_called_once_with(1)

    def test_extraction_timeout_exhaustion_cleans_up_and_fails_closed(self):
        directories = []
        before = self.config.read_bytes()

        def extract(arguments, **options):
            self.assertEqual(options, {'check': True, 'timeout': 600})
            destination = Path(next(arg[5:] for arg in arguments if arg.startswith('--to=')))
            self.assertTrue(all(not previous.exists() for previous in directories))
            directories.append(destination)
            (destination / 'partial').write_text('incomplete')
            raise subprocess.TimeoutExpired(arguments, 600)

        with patch.dict(os.environ, self.environment, clear=True), \
                patch.dict(NAMESPACE, {'release_info': lambda _image: {'metadata': {'version': CI_VERSION}}}), \
                patch.object(HELPER.subprocess, 'run', side_effect=extract) as extraction, \
                patch.object(HELPER.time, 'sleep') as sleep:
            with self.assertRaises(subprocess.TimeoutExpired):
                HELPER.prepare()
            self.assertEqual(extraction.call_count, 3)
            self.assertEqual(sleep.call_args_list, [call(1), call(2)])
        self.assertEqual(len(set(directories)), 3)
        self.assertTrue(all(not directory.exists() for directory in directories))
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.shared.iterdir()), [self.config])

    def test_invalid_catalog_is_not_retried_or_published(self):
        self.write_catalog(enabled=['AllAlpha'])
        before = self.config.read_bytes()
        with patch.dict(os.environ, self.environment, clear=True), \
                patch.dict(NAMESPACE, {'release_info': lambda _image: {'metadata': {'version': CI_VERSION}}}), \
                patch.object(HELPER.subprocess, 'run', side_effect=self.copy_catalog) as extraction, \
                patch.object(HELPER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'Invalid OpenShift feature gate'):
                HELPER.prepare()
            extraction.assert_called_once()
            sleep.assert_not_called()
            destination = Path(next(arg[5:] for arg in extraction.call_args.args[0] if arg.startswith('--to=')))
        self.assertFalse(destination.exists())
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.shared.iterdir()), [self.config])

    def test_missing_catalog_is_not_retried_or_published(self):
        before = self.config.read_bytes()
        with patch.dict(os.environ, self.environment, clear=True), \
                patch.dict(NAMESPACE, {'release_info': lambda _image: {'metadata': {'version': CI_VERSION}}}), \
                patch.object(HELPER.subprocess, 'run', side_effect=self.copy_catalog) as extraction, \
                patch.object(HELPER.time, 'sleep') as sleep:
            with self.assertRaisesRegex(ValueError, 'Missing or incompatible FeatureGate catalogs'):
                HELPER.prepare()
            extraction.assert_called_once()
            sleep.assert_not_called()
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(list(self.shared.iterdir()), [self.config])


class InstallerTests(FeatureGateFixtures):

    def test_ci_target_uses_installed_initial_catalog(self):
        lookups, extracts = self.prepare()
        self.assertEqual(lookups, ['target', 'initial'])
        self.assertIn('initial', extracts[0])
        self.assertNotIn('--included', extracts[0])
        self.assertIn('4.22', self.selection()['version'])
        config = yaml.safe_load(self.config.read_text())
        self.assertEqual(config['featureSet'], 'CustomNoUpgrade')
        self.assertEqual(config['featureGates'], ['Baseline=true', 'Disabled=true', 'ExtraKnown=true', 'Preview=true'])
        manifest = yaml.safe_load((self.shared / 'openshift_manifests_99_feature-gate.yaml').read_text())
        self.assertEqual(manifest['spec']['customNoUpgrade']['disabled'], [])
        self.assertEqual(set(manifest['spec']['customNoUpgrade']['enabled']),
                         {'Baseline', 'Disabled', 'ExtraKnown', 'Preview'})

    def test_nightly_and_ocp_targets_untouched(self):
        before = self.config.read_bytes()
        for target in [NIGHTLY_VERSION, '4.22.0-0.nightly-2026-10-23-000000',
                       '4.13.42', '5.0.0', '5.0.0-0.okd-scos-nightly-2026-10-23-035130-extra']:
            with self.subTest(target=target):
                lookups, extracts = self.prepare(target=target)
                self.assertEqual(lookups, ['target'])
                self.assertEqual(extracts, [])
                self.assertEqual(list(self.shared.iterdir()), [self.config])
                self.assertEqual(self.config.read_bytes(), before)

    def test_historical_and_arm64_ci_identities(self):
        for version in ['4.13.0-0.okd-2023-10-28-065448',
                        '4.15.0-0.okd-scos-2024-01-18-103522',
                        CI_VERSION, '5.1.0-0.okd-scos-arm64-2026-10-23-035130']:
            with self.subTest(version=version):
                self.assertIsNotNone(HELPER.CI_VERSION.fullmatch(version))

    def test_custom_ipi_initial_override(self):
        lookups, _ = self.prepare(CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE='custom-initial')
        self.assertEqual(lookups, ['target', 'custom-initial'])

    def test_shell_entrypoint_uses_oc_and_delivers_ipi_manifest(self):
        self.default_catalog()
        binary = self.directory / 'oc'
        binary.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys
if sys.argv[3] == 'info':
    print(json.dumps({'metadata': {'version': os.environ['TEST_VERSION']}}))
else:
    destination = Path(next(arg[5:] for arg in sys.argv if arg.startswith('--to=')))
    shutil.copytree(os.environ['TEST_CATALOG'], destination, dirs_exist_ok=True)
''')
        binary.chmod(0o755)
        result = subprocess.run(['bash', str(COMMAND)], env={
            **os.environ, **self.environment, 'TEST_VERSION': CI_VERSION,
            'TEST_CATALOG': str(self.catalog), 'PATH': str(self.directory) + ':' + os.environ['PATH'],
        }, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.shared / 'openshift_manifests_99_feature-gate.yaml').exists())

    def test_actual_ipi_shared_manifest_consumer_and_stableinitial_alias(self):
        self.prepare()
        source = REGISTRY / 'ipi/install/install/ipi-install-install-commands.sh'
        stable = REGISTRY / 'ipi/install/install/stableinitial/ipi-install-install-stableinitial-commands.sh'
        self.assertEqual(stable.resolve(), source.resolve())
        script = source.read_text()
        marker = 'echo "Will include following openshift config files:"'
        self.assertLess(script.index('${INSTALLER_BINARY} --dir="${dir}" create manifests &'),
                        script.index(marker))
        self.assertLess(script.index(marker),
                        script.index('${INSTALLER_BINARY} --dir="${dir}" create ignition-configs &'))
        consumer = script.split(marker, 1)[1].split('\n\n# Collect bootstrap logs', 1)[0]
        destination = self.directory / 'install/openshift'
        destination.mkdir(parents=True)
        manifest = destination / '99_feature-gate.yaml'
        manifest.write_text('spec: {featureSet: Default}\n')
        result = subprocess.run(['bash', '-euc', consumer], env={
            **os.environ, 'SHARED_DIR': str(self.shared), 'dir': str(destination.parent),
        }, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(manifest.read_bytes(),
                         (self.shared / 'okd-ci-featuregates/cluster-feature-gate.yaml').read_bytes())
        self.assertEqual(list(destination.iterdir()), [manifest])

    def test_workflow_installers_have_preparation_before_install(self):
        definitions = {}
        for kind in ['workflow', 'chain']:
            for path in REGISTRY.rglob('*-' + kind + '.yaml'):
                obj = yaml.safe_load(path.read_text())[kind]
                definitions[(kind, obj['as'])] = obj['steps']

        def flatten(steps):
            result = []
            for step in steps or []:
                result.extend(flatten(definitions[('chain', step['chain'])]) if 'chain' in step
                              else [step.get('ref')])
            return result

        for workflow, installer in [
                ('openshift-e2e-aws', 'ipi-install-install'),
                ('openshift-e2e-aws-ovn', 'ipi-install-install'),
                ('openshift-e2e-gcp', 'ipi-install-install'),
                ('openshift-e2e-vsphere', 'ipi-install-install'),
                ('openshift-upgrade-aws', 'ipi-install-install-stableinitial')]:
            with self.subTest(workflow=workflow):
                steps = flatten(definitions[('workflow', workflow)]['pre'])
                helper = 'openshift-featuregates-okd-ci'
                self.assertEqual(steps.count(helper), 1)
                self.assertLess(steps.index(helper), steps.index(installer))
        agent_workflows = 0
        for (kind, name), definition in definitions.items():
            if kind != 'workflow':
                continue
            steps = flatten(definition.get('pre') or [])
            if 'baremetalds-devscripts-setup' not in steps:
                continue
            with self.subTest(devscripts_workflow=name):
                self.assertFalse(any(step and step.startswith('openshift-featuregates-okd-ci')
                                     for step in steps))
                self.assertNotIn('ipi-install-install', steps)
                self.assertNotIn('ipi-install-install-stableinitial', steps)
            if name.startswith('agent-'):
                agent_workflows += 1
        self.assertGreater(agent_workflows, 0)
        self.assertIn('baremetalds-devscripts-setup',
                      flatten(definitions[('workflow', 'agent-e2e-sno-ipv6')]['pre']))
        provisioner = (REGISTRY / 'baremetalds/devscripts/setup/baremetalds-devscripts-setup-commands.sh').read_text()
        self.assertNotIn('okd-ci-featuregates', provisioner)
        self.assertNotIn('agent.mk', provisioner)
        self.assertFalse((STEP / 'agent').exists())
        upgrade = definitions[('workflow', 'openshift-upgrade-aws')]
        self.assertEqual(upgrade['dependencies']['OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'], 'release:initial')


if __name__ == '__main__':
    unittest.main()
