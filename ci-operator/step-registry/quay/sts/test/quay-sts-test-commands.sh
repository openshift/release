#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
python3 - <<'PYTHON'
import json
import os
import pathlib
import re
import subprocess

STATE_PATH = pathlib.Path(os.environ['SHARED_DIR']) / 'quay-sts-state.json'
os.environ['KUBECONFIG'] = str(pathlib.Path(os.environ['SHARED_DIR']) / 'kubeconfig')


def oc(*args):
    return subprocess.check_output(['oc', '--request-timeout=30s', *args], text=True)


def read_object(resource, name, namespace=None):
    args = ['get', resource, name, '-o', 'json']
    if namespace:
        args += ['-n', namespace]
    return json.loads(oc(*args))


def load_state():
    state = json.loads(STATE_PATH.read_text())
    run_id = state['run_id']
    if not re.fullmatch(r'[a-f0-9]{16}', run_id):
        raise RuntimeError('Invalid run identity')
    name = 'quay-sts-' + run_id
    if any(state[key] != name for key in ('namespace', 'bucket', 'role')):
        raise RuntimeError('Unexpected resource names in state')
    actual_cluster_uid = read_object('namespace', 'kube-system')['metadata']['uid']
    if state['cluster_uid'] != actual_cluster_uid:
        raise RuntimeError('State belongs to another cluster')
    return state


def verify_namespace(state):
    namespace = read_object('namespace', state['namespace'])
    metadata = namespace['metadata']
    if (metadata['uid'] != state['namespace_uid'] or
            metadata.get('labels', {}).get('quay.redhat.com/sts-ci-run') != state['run_id']):
        raise RuntimeError('Namespace is not owned by this run')


state = load_state()
verify_namespace(state)
namespace = state['namespace']
for key, expected in {'STS_TEST_NAMESPACE': namespace, 'STS_S3_BUCKET': state['bucket'],
                      'STS_S3_REGION': state['region'], 'STS_ROLE_ARN': state['role_arn']}.items():
    if (STATE_PATH.parent / key).read_text().strip() != expected:
        raise RuntimeError('Test input differs from provisioning state: ' + key)

operator_namespace = os.environ['QUAY_STS_OPERATOR_NAMESPACE']
operator = read_object(
    'deployment', os.environ['QUAY_STS_OPERATOR_DEPLOYMENT'], operator_namespace)
pod = operator['spec']['template']
containers = pod['spec']['containers']
managers = [container for container in containers
            if any(entry['name'] == 'ROLEARN' for entry in container.get('env', []))]
if len(managers) != 1:
    raise RuntimeError('Expected one operator container configured with ROLEARN')
env = {entry['name']: entry for entry in managers[0]['env']}
if env['ROLEARN'].get('value') != state['role_arn']:
    raise RuntimeError('Operator ROLEARN does not match provisioned role')
watch = env.get('WATCH_NAMESPACE', {})
watch_value = watch.get('value')
if watch.get('valueFrom', {}).get('fieldRef', {}).get('fieldPath') == "metadata.annotations['olm.targetNamespaces']":
    watch_value = pod['metadata'].get('annotations', {}).get('olm.targetNamespaces', '')
process_arguments = managers[0].get('command', []) + managers[0].get('args', [])
if watch_value not in ('', None) or '--namespace=$(WATCH_NAMESPACE)' not in process_arguments:
    raise RuntimeError('The ephemeral-cluster operator must use AllNamespaces mode')
oc('rollout', 'status', 'deployment/' + operator['metadata']['name'],
   '-n', operator_namespace, '--timeout=180s')
print('Ephemeral cluster, resource ownership, and operator checks passed')
PYTHON

for variable in STS_TEST_NAMESPACE STS_S3_BUCKET STS_S3_REGION STS_ROLE_ARN; do
  value=$(cat "${SHARED_DIR}/${variable}")
  [[ -n "$value" ]] || { echo "Missing ${variable}" >&2; exit 1; }
  export "${variable}=${value}"
done
export PATH="/tmp/quay-sts-bin:${PATH}"
for command in kubectl jq curl crane base64; do
  command -v "$command" >/dev/null
done
make test-e2e-sts \
  CHAINSAW_REPORT_FORMAT=XML CHAINSAW_REPORT_PATH="${ARTIFACT_DIR}" \
  CHAINSAW_REPORT_NAME=junit_quay_sts \
  CHAINSAW_EXTRA_ARGS="--assert-timeout 20m"
