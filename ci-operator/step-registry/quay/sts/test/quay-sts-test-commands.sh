#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG=/var/run/quay-qe-cluster/kubeconfig
python3 - <<'PYTHON'
import json
import os
import pathlib
import re
import subprocess

STATE_PATH = pathlib.Path(os.environ['SHARED_DIR']) / 'quay-sts-state.json'
CLUSTER_CREDENTIAL = pathlib.Path('/var/run/quay-qe-cluster')
os.environ['KUBECONFIG'] = str(CLUSTER_CREDENTIAL / 'kubeconfig')

def oc(*args):
    return subprocess.check_output(['oc', '--request-timeout=30s', *args], text=True)

def read_object(resource, name, namespace=None):
    args = ['get', resource, name, '-o', 'json']
    if namespace:
        args += ['-n', namespace]
    return json.loads(oc(*args))

def verify_cluster():
    expected = (CLUSTER_CREDENTIAL / 'cluster_uid').read_text().strip()
    actual = read_object('namespace', 'kube-system')['metadata']['uid']
    if not expected or actual != expected:
        raise RuntimeError('QE cluster identity mismatch; refusing to change resources')
    return actual

def save(state):
    temporary = STATE_PATH.with_suffix('.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(STATE_PATH)

def load_state(cluster_uid):
    state = json.loads(STATE_PATH.read_text())
    run_id = state['run_id']
    if not re.fullmatch(r'[a-f0-9]{16}', run_id):
        raise RuntimeError('Invalid run identity')
    name = 'quay-sts-' + run_id
    if any(state[key] != name for key in ('namespace', 'bucket', 'role')):
        raise RuntimeError('Unexpected resource names in state')
    if state['cluster_uid'] != cluster_uid:
        raise RuntimeError('State belongs to another cluster')
    return state

def verify_namespace(state):
    namespace = read_object('namespace', state['namespace'])
    metadata = namespace['metadata']
    if (metadata['uid'] != state['namespace_uid'] or
            metadata.get('labels', {}).get('quay.redhat.com/sts-ci-run') != state['run_id']):
        raise RuntimeError('Namespace is not owned by this run')
    return namespace
state = load_state(verify_cluster())
verify_namespace(state)
namespace = state['namespace']
for key, expected in {'STS_TEST_NAMESPACE': namespace, 'STS_S3_BUCKET': state['bucket'],
                      'STS_S3_REGION': state['region'], 'STS_ROLE_ARN': state['role_arn']}.items():
    if (STATE_PATH.parent / key).read_text().strip() != expected:
        raise RuntimeError('Test input differs from provisioning state: ' + key)
operator = read_object('deployment', os.environ['QUAY_STS_OPERATOR_DEPLOYMENT'], namespace)
pod = operator['spec']['template']
containers = pod['spec']['containers']
managers = [c for c in containers if any(e['name'] == 'ROLEARN' for e in c.get('env', []))]
if len(managers) != 1:
    raise RuntimeError('Expected one operator container configured with ROLEARN')
env = {e['name']: e for e in managers[0]['env']}
if env['ROLEARN'].get('value') != state['role_arn']:
    raise RuntimeError('Operator ROLEARN does not match provisioned role')
watch = env.get('WATCH_NAMESPACE', {})
watch_value = watch.get('value')
if watch.get('valueFrom', {}).get('fieldRef', {}).get('fieldPath') == "metadata.annotations['olm.targetNamespaces']":
    watch_value = pod['metadata'].get('annotations', {}).get('olm.targetNamespaces')
if watch_value != namespace or '--namespace=$(WATCH_NAMESPACE)' not in managers[0].get('args', []):
    raise RuntimeError('Operator must watch only this run namespace')
# Fail if another OLM-managed Quay operator can reconcile this namespace.
for csv in json.loads(oc('get', 'clusterserviceversions', '-A', '-o', 'json'))['items']:
    if csv.get('status', {}).get('reason') == 'Copied':
        continue
    owned = csv.get('spec', {}).get('customresourcedefinitions', {}).get('owned', [])
    if not any(crd['name'] == 'quayregistries.quay.redhat.com' for crd in owned):
        continue
    metadata = csv['metadata']
    targets = metadata.get('annotations', {}).get('olm.targetNamespaces', '')
    if metadata['namespace'] != namespace and (not targets or namespace in targets.split(',')):
        raise RuntimeError('Another OLM Quay operator overlaps the test namespace')
oc('rollout', 'status', 'deployment/' + operator['metadata']['name'], '-n', namespace, '--timeout=180s')
print('Shared-cluster identity, resource ownership, and operator scope checks passed')
PYTHON
for variable in STS_TEST_NAMESPACE STS_S3_BUCKET STS_S3_REGION STS_ROLE_ARN; do
  value=$(cat "${SHARED_DIR}/${variable}")
  [[ -n "$value" ]] || { echo "Missing ${variable}" >&2; exit 1; }
  export "${variable}=${value}"
done
mkdir -p /tmp/quay-sts-bin
ln -sf "$(command -v oc)" /tmp/quay-sts-bin/kubectl
export PATH="/tmp/quay-sts-bin:${PATH}"
# Pin helper versions; the source image contains Go and curl but not jq.
GOFLAGS="" GOBIN=/tmp/quay-sts-bin go install github.com/google/go-containerregistry/cmd/crane@v0.20.3
GOFLAGS="" GOBIN=/tmp/quay-sts-bin go install github.com/itchyny/gojq/cmd/gojq@v0.12.17
ln -sf /tmp/quay-sts-bin/gojq /tmp/quay-sts-bin/jq
for command in kubectl jq curl crane base64; do
  command -v "$command" >/dev/null
done
make test-e2e-sts \
  CHAINSAW_REPORT_FORMAT=XML CHAINSAW_REPORT_PATH="${ARTIFACT_DIR}" \
  CHAINSAW_REPORT_NAME=junit_quay_sts \
  CHAINSAW_EXTRA_ARGS="--assert-timeout 20m"
