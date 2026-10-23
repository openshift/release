#!/usr/bin/env python3

import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

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
LEGACY = '''
var FeatureSets = map[FeatureSet]*FeatureGateEnabledDisabled{
 Default: defaultFeatures,
 TechPreviewNoUpgrade: newDefaultFeatures().with("Preview").without("Baseline").toFeatures(),
}
var defaultFeatures = &FeatureGateEnabledDisabled{
 Enabled: []string{"Baseline"},
 Disabled: []string{"Disabled"},
}
'''
MODERN_DISPATCH = '''
\tif featureGates.Spec.FeatureSet == configv1.CustomNoUpgrade {
\t\tif featureGates.Spec.FeatureGateSelection.CustomNoUpgrade != nil {
\t\t\treturn completeFeatureGatesForCustom(
\t\t\t\tknownFeatureSets[configv1.Default],
\t\t\t\tfeatureGates.Spec.FeatureGateSelection.CustomNoUpgrade.Enabled,
\t\t\t\tfeatureGates.Spec.FeatureGateSelection.CustomNoUpgrade.Disabled,
\t\t\t)
\t\t}
\t\treturn completeFeatureGatesForCustom(knownFeatureSets[configv1.Default], []configv1.FeatureGateName{}, []configv1.FeatureGateName{})
\t}
'''
OLD_DISPATCH = '''
\tif featureGates.Spec.FeatureSet == configv1.CustomNoUpgrade {
\t\tif featureGates.Spec.FeatureGateSelection.CustomNoUpgrade != nil {
\t\t\tcompleteEnabled, completeDisabled := completeFeatureGates(knownFeatureSets, featureGates.Spec.FeatureGateSelection.CustomNoUpgrade.Enabled, featureGates.Spec.FeatureGateSelection.CustomNoUpgrade.Disabled)
\t\t\treturn completeEnabled, completeDisabled, nil
\t\t}
\t\treturn []configv1.FeatureGateName{}, []configv1.FeatureGateName{}, nil
\t}
'''


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
            'OPENSHIFT_INSTALL_RELEASE_IMAGE': 'agent-initial',
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
        (self.catalog / 'image-references').write_text(json.dumps({'spec': {'tags': [{
            'name': 'cluster-config-operator', 'annotations': {
                'io.openshift.build.source-location': 'https://github.com/openshift/cluster-config-operator',
                'io.openshift.build.commit.id': 'a' * 40}}]}}))

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
                patch.object(HELPER.subprocess, 'run', side_effect=extract), \
                patch.dict(NAMESPACE, {'pinned_source': lambda *_args: (MODERN_DISPATCH, 'pinned-consumer')}):
            HELPER.prepare()
        return lookups, extracts

    def selection(self):
        return json.loads((self.shared / 'okd-ci-featuregates/selection.json').read_text())


class CatalogTests(FeatureGateFixtures):
    def test_complete_catalog_including_nondefault_names(self):
        self.default_catalog()
        known, overrides = HELPER.catalog_gates(self.catalog, CI_VERSION)
        self.assertEqual(known, {'Baseline', 'Disabled', 'Preview', 'ExtraKnown'})
        self.assertEqual({'Baseline'} | overrides, known)
        self.assertEqual(known - ({'Baseline'} | overrides), set())
        self.assertFalse({'Baseline'} & overrides)

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
                result = HELPER.catalog_gates(self.catalog, CI_VERSION)
                self.assertEqual(result is not None, included)

    def test_null_disabled_and_enabled(self):
        self.write_catalog(enabled=['Baseline'])
        self.write_catalog('TechPreviewNoUpgrade', disabled=['Other'])
        self.assertEqual(HELPER.catalog_gates(self.catalog, CI_VERSION),
                         ({'Baseline', 'Other'}, {'Other'}))

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

    def test_legacy_union_and_strict_expressions(self):
        expected = {'Baseline', 'Preview', 'Disabled'}
        self.assertEqual(HELPER.legacy_gates(LEGACY), (expected, expected))
        for source in [LEGACY.replace('"Preview"', 'unresolvedVariable'),
                       LEGACY.replace('"Preview"', '"AllAlpha"'), '',
                       LEGACY.replace('"Preview"', '"Name-with-punctuation"')]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                HELPER.legacy_gates(source)

    def test_legacy_payload_pinned_source_only(self):
        references = {'spec': {'tags': [{
            'name': 'cluster-kube-apiserver-operator', 'annotations': {
                'io.openshift.build.source-location':
                    'https://github.com/openshift/cluster-kube-apiserver-operator',
                'io.openshift.build.commit.id': 'a' * 40}}]}}
        path = self.catalog / 'image-references'
        path.write_text(json.dumps(references))
        with patch.object(HELPER.urllib.request, 'urlopen', return_value=io.BytesIO(LEGACY.encode())) as fetch:
            result, source = HELPER.payload_gates(self.catalog, '4.13.0-0.okd-legacy')
            self.assertEqual(result[0], result[1])
            self.assertIn('/' + 'a' * 40 + '/vendor/', fetch.call_args.args[0])
            self.assertIn('sha256:', source)
        references['spec']['tags'][0]['annotations']['io.openshift.build.commit.id'] = 'main'
        path.write_text(json.dumps(references))
        with self.assertRaises(ValueError):
            HELPER.payload_gates(self.catalog, '4.13.0-0.okd-legacy')
        with self.assertRaises(ValueError):
            HELPER.payload_gates(self.catalog, CI_VERSION)

    def test_consumer_baseline_modes_and_unknown_dispatch(self):
        self.assertTrue(HELPER.inherits_default(MODERN_DISPATCH))
        self.assertFalse(HELPER.inherits_default(OLD_DISPATCH))
        for source in ['', MODERN_DISPATCH + OLD_DISPATCH,
                       OLD_DISPATCH.replace('completeFeatureGates(', 'unknownResolver(')]:
            with self.subTest(source=source), self.assertRaises(ValueError):
                HELPER.inherits_default(source)
        self.assertFalse(HELPER.inherits_default(OLD_DISPATCH + '\nfunc completeFeatureGatesForCustom() {}'))

    def test_old_serialized_catalog_forces_complete_set(self):
        self.default_catalog()
        for consumer, expected in [(OLD_DISPATCH, {'Baseline', 'Disabled', 'ExtraKnown', 'Preview'}),
                                   (MODERN_DISPATCH, {'Disabled', 'ExtraKnown', 'Preview'})]:
            with self.subTest(consumer=consumer), \
                    patch.dict(NAMESPACE, {'pinned_source': lambda *_args, consumer=consumer: (consumer, 'pinned-source')}):
                (known, forced), source = HELPER.payload_gates(self.catalog, '4.15.0')
                self.assertEqual(forced, expected)
                enabled = forced if consumer == OLD_DISPATCH else forced | {'Baseline'}
                self.assertEqual(enabled, known)
                self.assertFalse(known - enabled)
                self.assertIn('Default inheritance=', source)


class InstallerTests(FeatureGateFixtures):

    def test_ci_target_uses_installed_initial_catalog(self):
        lookups, extracts = self.prepare()
        self.assertEqual(lookups, ['target', 'initial'])
        self.assertIn('initial', extracts[0])
        self.assertNotIn('--included', extracts[0])
        self.assertIn('4.22', self.selection()['version'])
        config = yaml.safe_load(self.config.read_text())
        self.assertEqual(config['featureSet'], 'CustomNoUpgrade')
        self.assertEqual(config['featureGates'], ['Disabled=true', 'ExtraKnown=true', 'Preview=true'])
        manifest = yaml.safe_load((self.shared / 'openshift_manifests_99_feature-gate.yaml').read_text())
        self.assertEqual(manifest['spec']['customNoUpgrade']['disabled'], [])
        self.assertEqual(set(manifest['spec']['customNoUpgrade']['enabled']) | {'Baseline'},
                         set(self.selection()['known']))

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

    def test_legacy_install_config_omits_unsupported_field(self):
        HELPER.configure_install_config(self.config, {'version': '4.13.0', 'overrides': ['Legacy']})
        self.assertEqual(yaml.safe_load(self.config.read_text()), {'featureSet': 'CustomNoUpgrade'})

    def test_agent_initial_source_and_early_staging(self):
        for architecture, expected in [('amd64', 'agent-initial'), ('arm64', 'initial')]:
            with self.subTest(architecture=architecture):
                prepared = self.shared / 'okd-ci-featuregates'
                if prepared.exists():
                    shutil.rmtree(prepared)
                before = self.config.read_bytes()
                lookups, _ = self.prepare(OKD_CI_FEATURE_GATES_INSTALLER='agent',
                                          ARCHITECTURE=architecture)
                self.assertEqual(lookups, ['target', expected])
                self.assertEqual(before, self.config.read_bytes())
                self.assertIn('agent_create_cluster: okd-ci-featuregates',
                              (prepared / 'agent.mk').read_text())
                self.assertIn('okd-ci-featuregates: agent_configure',
                              (prepared / 'agent.mk').read_text())

    def test_agent_ztp_overrides_and_extra_manifests(self):
        self.prepare(OKD_CI_FEATURE_GATES_INSTALLER='agent')
        agent = self.directory / 'agent'
        manifests = agent / 'cluster-manifests'
        manifests.mkdir(parents=True)
        path = manifests / 'agent-cluster-install.yaml'
        path.write_text(yaml.safe_dump({'metadata': {'annotations': {
            'other': 'unchanged', HELPER.OVERRIDES: json.dumps({'fips': True, 'featureSet': 'Default'})}}}))
        HELPER.configure_agent(agent, self.shared / 'okd-ci-featuregates')
        annotations = yaml.safe_load(path.read_text())['metadata']['annotations']
        overrides = json.loads(annotations[HELPER.OVERRIDES])
        self.assertEqual(overrides['featureSet'], 'CustomNoUpgrade')
        self.assertEqual(overrides['featureGates'], ['Disabled=true', 'ExtraKnown=true', 'Preview=true'])
        self.assertTrue(overrides['fips'])
        self.assertEqual(annotations['other'], 'unchanged')
        self.assertTrue((agent / 'openshift/99_feature-gate.yaml').exists())

    def test_agent_install_config_and_missing_configuration(self):
        self.prepare(OKD_CI_FEATURE_GATES_INSTALLER='agent')
        prepared = self.shared / 'okd-ci-featuregates'
        HELPER.configure_agent(self.shared, prepared)
        self.assertEqual(yaml.safe_load(self.config.read_text())['featureSet'], 'CustomNoUpgrade')
        with self.assertRaises(ValueError):
            HELPER.configure_agent(self.directory, prepared)

    def test_agent_hook_consumes_config_before_image(self):
        self.prepare(OKD_CI_FEATURE_GATES_INSTALLER='agent')
        prepared = self.shared / 'okd-ci-featuregates'
        hook = prepared / 'agent.mk'
        hook.write_text(hook.read_text().replace('/root/okd-ci-featuregates', str(prepared)))
        (self.directory / 'common.sh').write_text('OCP_DIR=ocp/ostest\n')
        manifests = self.directory / 'ocp/ostest/cluster-manifests'
        manifests.mkdir(parents=True)
        (manifests / 'agent-cluster-install.yaml').write_text('metadata: {}\n')
        recipe = next(line.strip().replace('$$', '$') for line in hook.read_text().splitlines()
                      if line.startswith('\t'))
        result = subprocess.run(['bash', '-c', recipe], cwd=self.directory,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = yaml.safe_load((manifests.parent / 'openshift/99_feature-gate.yaml').read_text())
        self.assertEqual(manifest['spec']['featureSet'], 'CustomNoUpgrade')

    def test_shell_entrypoint_uses_oc_and_delivers_ipi_manifest(self):
        self.default_catalog()
        consumer = self.directory / 'consumer.go'
        consumer.write_text(MODERN_DISPATCH)
        (self.directory / 'sitecustomize.py').write_text(
            'import os\nimport urllib.request\n'
            'urllib.request.urlopen = lambda *_args, **_kwargs: open(os.environ["TEST_CONSUMER"], "rb")\n')
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
            'PYTHONPATH': str(self.directory), 'TEST_CONSUMER': str(consumer),
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

    def test_remote_agent_setup_does_not_reuse_stale_ci_artifacts(self):
        self.prepare(OKD_CI_FEATURE_GATES_INSTALLER='agent')
        source = (REGISTRY / 'baremetalds/devscripts/setup/baremetalds-devscripts-setup-commands.sh').read_text()
        preparation = 'okd_ci_featuregates=false' + source.split('okd_ci_featuregates=false', 1)[1].split(
            '\n\n# Copy any additional manifests', 1)[0]
        hook = source.split('set +e\n', 1)[1].split('timeout -s 9 ${MAKE_TIMEOUT}', 1)[0]
        hook = hook.replace('/root/okd-ci-featuregates', str(self.directory / 'stale'))
        (self.directory / 'stale').mkdir()
        (self.directory / 'stale/agent.mk').write_text('stale content\n')
        empty = self.directory / 'nightly-shared'
        empty.mkdir()
        script = ('SSHOPTS=()\nIP=unused\n'
                  'scp() { printf "%s\\n" "$*" > "$TEST_SCP"; }\n' + preparation
                  + '\ncat <<EOF > "$TEST_REMOTE"\n' + hook
                  + '\nprintf "%s" "\\${MAKEFILES:-}"\nEOF\nbash "$TEST_REMOTE"\n')
        for shared, enabled in [(empty, False), (self.shared, True)]:
            with self.subTest(enabled=enabled):
                result = subprocess.run(['bash', '-euc', script], env={
                    **os.environ, 'SHARED_DIR': str(shared), 'MAKEFILES': 'preserved.mk',
                    'TEST_SCP': str(self.directory / 'scp-arguments'),
                    'TEST_REMOTE': str(self.directory / 'remote.sh'),
                }, text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = str(self.directory / 'stale/agent.mk') + ' preserved.mk' if enabled else 'preserved.mk'
                self.assertEqual(result.stdout, expected)
                if enabled:
                    self.assertIn('root@unused:/root/', (self.directory / 'scp-arguments').read_text())
                else:
                    self.assertFalse((self.directory / 'scp-arguments').exists())

    def test_workflow_installers_have_preparation_before_install(self):
        definitions = {}
        for kind in ['workflow', 'chain']:
            for path in REGISTRY.rglob('*-' + kind + '.yaml'):
                obj = yaml.safe_load(path.read_text())[kind]
                definitions[(kind, obj['as'])] = obj['steps']

        def flatten(steps):
            result = []
            for step in steps:
                result.extend(flatten(definitions[('chain', step['chain'])]) if 'chain' in step
                              else [step.get('ref')])
            return result

        for workflow, installer in [
                ('openshift-e2e-aws', 'ipi-install-install'),
                ('openshift-e2e-aws-ovn', 'ipi-install-install'),
                ('openshift-e2e-gcp', 'ipi-install-install'),
                ('openshift-e2e-vsphere', 'ipi-install-install'),
                ('openshift-upgrade-aws', 'ipi-install-install-stableinitial'),
                ('agent-e2e-sno-ipv6', 'baremetalds-devscripts-setup')]:
            with self.subTest(workflow=workflow):
                steps = flatten(definitions[('workflow', workflow)]['pre'])
                helper = 'openshift-featuregates-okd-ci'
                if workflow.startswith('agent'):
                    helper += '-agent'
                self.assertEqual(steps.count(helper), 1)
                self.assertLess(steps.index(helper), steps.index(installer))
        upgrade = definitions[('workflow', 'openshift-upgrade-aws')]
        self.assertEqual(upgrade['dependencies']['OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE'], 'release:initial')


if __name__ == '__main__':
    unittest.main()
