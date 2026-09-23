#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  exit 0
fi
umask 077
WORK_DIR=$(mktemp -d /tmp/ibi-hub-prepare.XXXXXX)
trap 'rm -rf "${WORK_DIR}"' EXIT
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_TIMEOUT=600

cat > "${WORK_DIR}/ready.py" <<'PY'
import json
import subprocess
import sys
import time

kubeconfig = sys.argv[1]


def oc(*args):
    result = subprocess.run(
        ['oc', '--kubeconfig', kubeconfig, '--request-timeout=30s', *args],
        text=True, capture_output=True,
    )
    if result.returncode and args[:2] == ('auth', 'can-i') and result.stdout.strip() == 'no':
        return 'no'
    if result.returncode:
        # Do not print server addresses or credential-bearing command arguments.
        raise RuntimeError('Hub API command failed: ' + ' '.join(args[:2]))
    return result.stdout.strip()


def read(*args):
    return json.loads(oc('get', *args, '-o', 'json'))


def wait_for(description, check):
    deadline = time.monotonic() + 600
    while True:
        if check():
            print(description + ': ready', flush=True)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(description + ': timed out after 600 seconds')
        time.sleep(10)


def deployment_ready(namespace, name):
    raw = oc('get', 'deployment', name, '-n', namespace,
             '--ignore-not-found', '-o', 'json')
    if not raw:
        return False
    obj = json.loads(raw)
    status = obj.get('status', {})
    desired = obj.get('spec', {}).get('replicas', 1)
    return (desired > 0
            and status.get('observedGeneration', 0) >= obj['metadata']['generation']
            and status.get('updatedReplicas', 0) == desired
            and status.get('replicas', 0) == desired
            and status.get('availableReplicas', 0) == desired)


mch = read('multiclusterhub', 'multiclusterhub', '-n', 'open-cluster-management')
overrides = mch['spec'].get('overrides', {})
components = overrides.get('components', [])
siteconfig = [item for item in components if item.get('name') == 'siteconfig']
if len(siteconfig) > 1:
    raise RuntimeError('Multiple SiteConfig component entries in MultiClusterHub')
if not siteconfig or siteconfig[0].get('enabled') is not True:
    components = [dict(item, enabled=True) if item.get('name') == 'siteconfig'
                  else item for item in components]
    if not siteconfig:
        components.append({'name': 'siteconfig', 'enabled': True})
    # Resource version prevents overwriting a concurrent controller update.
    patch = {'metadata': {'resourceVersion': mch['metadata']['resourceVersion']},
             'spec': {'overrides': {'components': components}}}
    oc('patch', 'multiclusterhub', 'multiclusterhub', '-n', 'open-cluster-management',
       '--type=merge', '-p', json.dumps(patch))

wait_for('SiteConfig controller', lambda: deployment_ready(
    'multicluster-engine', 'siteconfig-controller-manager'))


def crd_ready():
    raw = oc('get', 'crd', 'clusterinstances.siteconfig.open-cluster-management.io',
             '--ignore-not-found', '-o', 'json')
    return bool(raw) and any(c.get('type') == 'Established' and c.get('status') == 'True'
                            for c in json.loads(raw).get('status', {}).get('conditions', []))


wait_for('ClusterInstance CRD', crd_ready)
csv = None


def talm_installed():
    global csv
    subscriptions = read('subscriptions.operators.coreos.com', '-n', 'openshift-operators')
    matches = [s for s in subscriptions['items']
               if s.get('spec', {}).get('name') == 'topology-aware-lifecycle-manager']
    if len(matches) != 1:
        raise RuntimeError('Expected exactly one TALM Subscription in openshift-operators')
    name = matches[0].get('status', {}).get('installedCSV')
    if not name:
        return False
    raw = oc('get', 'csv', name, '-n', 'openshift-operators', '--ignore-not-found', '-o', 'json')
    csv = json.loads(raw) if raw else None
    return csv is not None and csv.get('status', {}).get('phase') == 'Succeeded'


wait_for('TALM installed CSV', talm_installed)
deployments = csv['spec']['install']['spec']['deployments']
if not deployments:
    raise RuntimeError('TALM CSV contains no deployments')
for deployment in deployments:
    name = deployment['name']
    wait_for('TALM deployment ' + name,
             lambda: deployment_ready('openshift-operators', name))
    live = read('deployment', name, '-n', 'openshift-operators')
    account = live['spec']['template']['spec'].get('serviceAccountName', 'default')
    for resource in ('policies.policy.open-cluster-management.io',
                     'clustergroupupgrades.ran.openshift.io'):
        # A denied check is a hard failure, not a reason to grant extra privileges.
        answer = oc('auth', 'can-i', 'list', resource, '--all-namespaces',
                    '--as=system:serviceaccount:openshift-operators:' + account)
        if answer != 'yes':
            raise RuntimeError('TALM service account cannot list ' + resource)
print('IBI hub prerequisites verified', flush=True)
PY

for hub in seed target; do
  cluster="${CLUSTER_NAME}"
  if [[ "${hub}" == target ]]; then
    cluster="${TARGET_CLUSTER_NAME}"
  fi
  python3 - "${SHARED_DIR}" "${hub}" "${WORK_DIR}" <<'PY'
import json
import pathlib
import sys
import yaml
shared, hub, work = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
variables = {}
for group in ('all', 'bastions', 'bastion'):
    with (shared / (hub + '-' + group)).open() as stream:
        values = yaml.safe_load(stream)
    if not isinstance(values, dict):
        raise RuntimeError('Expected mapping in saved hub inventory')
    variables.update(values)
key = variables.pop('ansible_ssh_private_key')
key_path = work / (hub + '.key')
key_path.write_text(key.rstrip() + '\n')
key_path.chmod(0o600)
variables['ansible_ssh_private_key_file'] = str(key_path)
variables['ansible_private_key_file'] = str(key_path)
(work / (hub + '.json')).write_text(json.dumps({'all': {'hosts': {'bastion': variables}}}))
PY
  echo "Preparing ${hub} hub prerequisites"
  ansible bastion -i "${WORK_DIR}/${hub}.json" \
    -m ansible.builtin.script \
    -a "${WORK_DIR}/ready.py /home/telcov10n/project/generated/${cluster}/auth/kubeconfig executable=python3"
done
