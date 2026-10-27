#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'ci-operator/step-registry/gather/extra/gather-extra-commands.sh'
SOURCE = SCRIPT.read_text()
QUEUE = SOURCE[SOURCE.index('function queue()'):SOURCE.index('if test ! -f "${KUBECONFIG}"')]
NETWORK = SOURCE[SOURCE.index('function gather_network_snapshot()'):SOURCE.index('# Gather network details')]
DISPATCH = SOURCE[SOURCE.index('# Gather network details'):SOURCE.index('while IFS= read -r i; do', SOURCE.index('# Gather network details'))]
RUNNER = QUEUE + NETWORK + r'''
oc() {
  printf '%s\n' "$*" >> "$all_calls"
  if [[ " $* " == *" get ns "* ]]; then
    [[ "$scenario" != namespace-error ]]
  elif [[ " $* " == *" get "* ]]; then
    if [[ "$scenario" == list-error ]]; then return 1; fi
    if [[ " $* " == *" get no "* ]]; then
      python3 -c 'import json, os; print(json.load(open(os.environ["nodes"]))["items"][0]["metadata"]["name"])'
      return
    fi
    if [[ " $* " == *" get node "* ]]; then
      python3 -c 'import json, os; print(json.load(open(os.environ["nodes"]))["items"][0]["metadata"]["annotations"].get("k8s.ovn.org/zone-name", ""))'
      return
    fi
    [[ " $* " == *" pods "* ]] || return 99
    cat "$fixture"
  else
    printf '%s\n' "$*" >> "$calls"
    if [[ "$scenario" == command-error ]]; then echo 'fixture failure' >&2; return 42; fi
    if [[ "$scenario" == missing-nft && " $* " == *" nft "* ]]; then return 127; fi
    if [[ "$scenario" == hanging ]]; then sleep 5; fi
    if [[ "$scenario" != empty-output ]]; then echo 'fixture snapshot'; fi
  fi
}
export -f oc
timeout() {
  [[ "$1" == --kill-after=5s && "$2" == 30s ]] || return 99
  shift 2
  local duration=30s
  if [[ "$scenario" == hanging ]]; then duration=0.1s; fi
  command timeout --kill-after=5s "$duration" bash -c '"$@"' _ "$@"
}
if [[ "$namespace" == dispatch ]]; then
''' + DISPATCH + r'''
else
  gather_network "$namespace" app=network "$container"
fi
wait
'''


def pod(name, node, container='ovnkube-controller', host_network=True):
    return {'metadata': {'name': name}, 'spec': {
        'nodeName': node, 'hostNetwork': host_network,
        'containers': [{'name': container}],
    }}


class NetworkTests(unittest.TestCase):
    def test_production_template_locally(self):
        if not shutil.which('oc'):
            self.skipTest('oc is required to check its local template formatter')
        command = shlex.split(next(line for line in NETWORK.splitlines() if ' pods --template ' in line))
        template = command[command.index('--template') + 1]
        objects = [pod('pod-a', 'node-a'), pod('pod-b', None, 'ovnkube-node', host_network=False)]
        for item in objects:
            item.update(apiVersion='v1', kind='Pod')
        result = subprocess.run(
            ['oc', 'process', '--local', '-f', '-', '-o', 'go-template=' + template],
            input=json.dumps({'apiVersion': 'template.openshift.io/v1', 'kind': 'Template',
                              'metadata': {'name': 'fixture'}, 'objects': objects}),
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'pod-a\tnode-a\ttrue\tovnkube-controller,\npod-b\t<none>\tfalse\tovnkube-node,\n')

    def run_gather(self, pods, scenario='', namespace='openshift-ovn-kubernetes', container='ovn', zone=None):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        artifacts = directory / 'network'
        artifacts.mkdir()
        fixture = directory / 'pods.tsv'
        fixture.write_text(''.join(
            '\t'.join((item['metadata']['name'], item['spec']['nodeName'] or '<none>',
                       str(item['spec']['hostNetwork']).lower(),
                       ','.join(entry['name'] for entry in item['spec']['containers']))) + '\n'
            for item in pods
        ))
        nodes = directory / 'nodes.json'
        metadata = {'name': 'node-a', 'annotations': {}}
        if zone is not None:
            metadata['annotations']['k8s.ovn.org/zone-name'] = zone
        nodes.write_text(json.dumps({'items': [{'metadata': metadata}]}))
        calls = directory / 'calls'
        all_calls = directory / 'all-calls'
        result = subprocess.run(['bash', '-e', '-c', RUNNER], check=False, capture_output=True, text=True, env=dict(
            os.environ, ARTIFACT_DIR=str(directory), fixture=str(fixture), calls=str(calls),
            all_calls=str(all_calls), nodes=str(nodes), scenario=scenario, namespace=namespace, container=container,
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(' get node ', all_calls.read_text())
        self.assertNotIn(' get no ', all_calls.read_text())
        return result, artifacts, calls.read_text().splitlines() if calls.exists() else []

    def test_modern_annotations_do_not_select_container(self):
        for zone in (None, 'node-a', 'different-zone'):
            with self.subTest(zone=zone):
                result, artifacts, calls = self.run_gather([pod('pod-a', 'node-a')], zone=zone)
                self.assertEqual(len(calls), 3)
                self.assertTrue(all('-c ovnkube-controller pod-a ' in call for call in calls))
                self.assertTrue(any('nft list ruleset' in call for call in calls))
                self.assertIn('on node-a using ovnkube-controller', result.stdout)
                self.assertEqual(len(list(artifacts.iterdir())), 3)
                self.assertTrue(all(path.stat().st_size for path in artifacts.iterdir()))

    def test_mixed_nodes_and_layouts(self):
        for zone in (None, 'node-b'):
            with self.subTest(zone=zone):
                result, artifacts, calls = self.run_gather([
                    pod('pod-a', 'node-a'), pod('pod-b', 'node-b', 'ovnkube-node'),
                ], zone=zone)
                self.assertEqual(len(calls), 5)
                self.assertTrue(all('-c ovnkube-controller pod-a ' in call for call in calls if 'pod-a ' in call))
                self.assertTrue(all('-c ovnkube-node pod-b ' in call for call in calls if 'pod-b ' in call))
                self.assertFalse(any('pod-b nft' in call for call in calls))
                self.assertIn('on node-b using ovnkube-node (iptables)', result.stdout)
                self.assertTrue((artifacts / 'iptables-save-pod-b').is_file())

    def test_sdn(self):
        _, _, calls = self.run_gather([pod('sdn-pod', 'node-a', 'sdn')], namespace='openshift-sdn', container='sdn')
        self.assertEqual(len(calls), 2)
        self.assertTrue(all('-c sdn sdn-pod ' in call for call in calls))

    def test_unsupported_targets_do_not_prevent_valid_pod_collection(self):
        result, artifacts, calls = self.run_gather([
            pod('unknown', 'node-a', 'other'), pod('not-host', 'node-b', host_network=False),
            pod('unscheduled', None), pod('valid', 'node-c'),
        ])
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(' valid ' in call for call in calls))
        self.assertEqual(len(list(artifacts.glob('target-*.error'))), 3)
        self.assertIn('No supported host-network container', result.stderr)

    def test_no_pods_and_api_errors(self):
        for scenario in ('', 'namespace-error', 'list-error'):
            with self.subTest(scenario=scenario):
                result, _, calls = self.run_gather([], scenario)
                self.assertEqual(calls, [])
                self.assertTrue(result.stdout or result.stderr)

    def test_command_errors_and_empty_output(self):
        for scenario in ('command-error', 'empty-output', 'hanging'):
            with self.subTest(scenario=scenario):
                result, artifacts, calls = self.run_gather([pod('pod-a', 'node-a')], scenario)
                self.assertEqual(len(calls), 3)
                self.assertEqual(len(list(artifacts.glob('*.error'))), 3)
                self.assertEqual(len(list(artifacts.iterdir())), 3)
                self.assertIn('ERROR: Network snapshot', result.stderr)
                if scenario == 'command-error':
                    self.assertTrue(all('fixture failure' in path.read_text() for path in artifacts.iterdir()))
                if scenario == 'hanging':
                    self.assertTrue(all('exit 124' in path.read_text() for path in artifacts.iterdir()))

    def test_missing_nft_does_not_discard_other_snapshots(self):
        _, artifacts, _ = self.run_gather([pod('pod-a', 'node-a')], 'missing-nft')
        self.assertIn('exit 127', (artifacts / 'nft-list-ruleset-pod-a.error').read_text())
        self.assertTrue((artifacts / 'iptables-save-pod-a').is_file())
        self.assertTrue((artifacts / 'ss-pod-a').is_file())

    def test_no_valid_target(self):
        result, artifacts, calls = self.run_gather([pod('unknown', 'node-a', 'other')])
        self.assertEqual(calls, [])
        self.assertTrue((artifacts / 'target-unknown.error').is_file())
        self.assertIn('No supported host-network container', result.stderr)

    def test_production_dispatch(self):
        _, artifacts, calls = self.run_gather([pod('pod-a', 'node-a')], namespace='dispatch')
        all_calls = (artifacts.parent / 'all-calls').read_text()
        self.assertIn('get -n openshift-sdn -l app=sdn pods --template', all_calls)
        self.assertIn('get -n openshift-ovn-kubernetes -l app=ovnkube-node pods --template', all_calls)
        self.assertTrue(all('-n openshift-ovn-kubernetes -c ovnkube-controller pod-a ' in call for call in calls))
        self.assertTrue((artifacts / 'target-pod-a.error').is_file())


if __name__ == '__main__':
    unittest.main(verbosity=2)
