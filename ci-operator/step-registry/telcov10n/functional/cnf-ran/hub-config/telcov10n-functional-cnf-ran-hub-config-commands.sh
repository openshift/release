#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

process_inventory() {
  local directory="$1"
  local dest_file="$2"

  if [ -z "$directory" ]; then
    echo "Usage: process_inventory <directory> <dest_file>"
    return 1
  fi

  if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a valid directory"
    return 1
  fi

  find "$directory" -type f | while IFS= read -r filename; do
    if [[ $filename == *"secretsync-vault-source-path"* ]]; then
      continue
    fi
    local content
    content=$(cat "$filename")
    local varname
    varname=$(basename "${filename}")
    if [[ "$content" == *$'\n'* ]]; then
      echo "${varname}: |"
      echo "$content" | sed 's/^/  /'
    else
      echo "${varname}": \'"${content}"\'
    fi
  done > "${dest_file}"
}

echo "Processing common group_vars"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Copying host_vars from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp "${SHARED_DIR}/master0" /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}"

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

PROJECT_DIR="/tmp"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/ansible_ssh_key"
chmod 600 "${PROJECT_DIR}/ansible_ssh_key"
export ANSIBLE_PRIVATE_KEY_FILE="${PROJECT_DIR}/ansible_ssh_key"

export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_TIMEOUT=600
export ANSIBLE_HOST_KEY_CHECKING=False

VERSION_TAG=$(echo "${VERSION}" | tr '.' '-')
export VERSION_TAG
echo "VERSION_TAG=${VERSION_TAG}"

HUB_OPERATORS=$(echo "${HUB_OPERATORS}" | sed "s/\${VERSION_TAG}/${VERSION_TAG}/g")
echo "HUB_OPERATORS=${HUB_OPERATORS}"

cd /eco-ci-cd/

echo "Deploying hub operators (VERSION=${VERSION}, VERSION_TAG=${VERSION_TAG})"

if [[ "$VERSION" == "4.14" ]]; then
  echo "Applying ose-kube-rbac-proxy workaround for 4.14"
  ansible-playbook playbooks/ran/mirror-ose-kube-rbac-proxy-wa.yml \
    -i inventories/ocp-deployment/build-inventory.py \
    --extra-vars "version=$VERSION"
fi

SKIP_REGISTRY_CLEANUP=""
if [[ "$VERSION" == "4.14" ]]; then
  SKIP_REGISTRY_CLEANUP="ocp_operator_mirror_skip_internal_registry_cleanup=true"
fi

echo "Running deploy-ocp-operators"
ansible-playbook ./playbooks/deploy-ocp-operators.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=$VERSION disconnected=$DISCONNECTED operators='$HUB_OPERATORS' $SKIP_REGISTRY_CLEANUP"

echo "Configuring LVM storage"
ansible-playbook playbooks/ran/hub-sno-configure-lvm-storage.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --private-key="${PROJECT_DIR}/ansible_ssh_key" \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH}" \
  --extra-vars "{\"lvm_local_volumes\": ${LVM_LOCAL_VOLUMES}}" -vv

echo "Configuring ACM"
ansible-playbook playbooks/ran/hub-sno-configure-acm.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv


# Keep this block identical in the seed and target hub-config steps.
if [[ "${ENSURE_IBI_HUB_READY:-false}" == "true" ]]; then
  READY_SCRIPT=$(mktemp /tmp/ibi-hub-ready.XXXXXX.py)
  cat > "${READY_SCRIPT}" <<'PY'
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
  if ansible bastion -i ./inventories/ocp-deployment/build-inventory.py \
    -m ansible.builtin.script \
    -a "${READY_SCRIPT} ${KUBECONFIG_PATH} executable=python3"; then
    rm -f "${READY_SCRIPT}"
  else
    rm -f "${READY_SCRIPT}"
    exit 1
  fi
fi

echo "Configuring kustomize plugin"
ansible-playbook playbooks/ran/hub-sno-configure-kustomize-plugin.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

echo "Configuring GitOps"
ansible-playbook playbooks/ran/hub-sno-configure-gitops.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} gitlab_repo_url=${GITLAB_REPO_URL}" -vv
