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
  --extra-vars "kubeconfig=${KUBECONFIG_PATH}" -vv

echo "Configuring ACM"
ansible-playbook playbooks/ran/hub-sno-configure-acm.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

echo "Configuring kustomize plugin"
ansible-playbook playbooks/ran/hub-sno-configure-kustomize-plugin.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

echo "Configuring GitOps"
ansible-playbook playbooks/ran/hub-sno-configure-gitops.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} gitlab_repo_url=${GITLAB_REPO_URL}" -vv
