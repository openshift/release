#!/bin/bash
set -euo pipefail
set +x
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
[[ -f "${SHARED_DIR}/quay-sts-state.json" ]] || exit 0
python3 - <<'PYTHON'
import json
import os
import pathlib
import re
import subprocess

state_path = pathlib.Path(os.environ['SHARED_DIR']) / 'quay-sts-state.json'
state = json.loads(state_path.read_text())
run_id = state['run_id']
if not re.fullmatch(r'[a-f0-9]{16}', run_id):
    raise RuntimeError('Invalid run identity')
namespace_name = 'quay-sts-' + run_id
if state['namespace'] != namespace_name:
    raise RuntimeError('Unexpected namespace in state')
os.environ['KUBECONFIG'] = str(pathlib.Path(os.environ['SHARED_DIR']) / 'kubeconfig')


def oc(*args):
    return subprocess.check_output(['oc', '--request-timeout=30s', *args], text=True)


actual_cluster_uid = json.loads(oc('get', 'namespace', 'kube-system', '-o', 'json'))['metadata']['uid']
if actual_cluster_uid != state['cluster_uid']:
    raise RuntimeError('State belongs to another cluster')
raw_namespace = oc('get', 'namespace', namespace_name, '--ignore-not-found', '-o', 'json')
if not raw_namespace.strip():
    raise SystemExit(0)
namespace = json.loads(raw_namespace)
metadata = namespace['metadata']
if (metadata['uid'] != state['namespace_uid'] or
        metadata.get('labels', {}).get('quay.redhat.com/sts-ci-run') != run_id):
    raise RuntimeError('Namespace is not owned by this run')

quay_crd = oc('get', 'crd', 'quayregistries.quay.redhat.com',
              '--ignore-not-found', '-o', 'name')
if quay_crd.strip():
    subprocess.check_call([
        'oc', '--request-timeout=30s', 'delete', 'quayregistry/sts-cco',
        '-n', namespace_name, '--ignore-not-found', '--wait=true', '--timeout=20m'])
subprocess.check_call([
    'oc', '--request-timeout=30s', 'delete', 'namespace', namespace_name,
    '--wait=true', '--timeout=10m'])
print('Removed the run-owned Quay STS namespace')
PYTHON
