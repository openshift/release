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
  find "$directory" -type f | while IFS= read -r filename; do
    if [[ $filename == *"secretsync-vault-source-path"* ]]; then continue; fi
    local content varname
    content=$(cat "$filename")
    varname=$(basename "${filename}")
    if [[ "$content" == *$'\n'* ]]; then
      echo "${varname}: |"
      echo "$content" | sed 's/^/  /'
    else
      echo "${varname}": \'"${content//\'/\'\'\'}"\'
    fi
  done > "${dest_file}"
}

echo "Copying inventory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

if [[ -f "${SHARED_DIR}/bastion" ]]; then
  # Full workflow: hub-deploy wrote the complete inventory to SHARED_DIR.
  cp "${SHARED_DIR}/all"        /eco-ci-cd/inventories/ocp-deployment/group_vars/all
  cp "${SHARED_DIR}/bastions"   /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
  cp "${SHARED_DIR}/hypervisors" /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
  cp "${SHARED_DIR}/nodes"      /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes
  cp "${SHARED_DIR}/masters"    /eco-ci-cd/inventories/ocp-deployment/group_vars/masters
  cp "${SHARED_DIR}/bastion"    /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
  cp "${SHARED_DIR}/hypervisor" /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor
  cp "${SHARED_DIR}/master0"    /eco-ci-cd/inventories/ocp-deployment/host_vars/master0
else
  # Standalone: use credential mounts; hypervisors/hypervisor are not needed
  # for mirror-only operations so create empty placeholders.
  echo "SHARED_DIR inventory not found — using credential mounts (standalone run)"
  process_inventory /var/group_variables/common/all        /eco-ci-cd/inventories/ocp-deployment/group_vars/all
  process_inventory /var/group_variables/common/bastions   /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
  process_inventory /var/group_variables/common/hypervisors /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
  process_inventory /var/group_variables/kni-qe-129/nodes  /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes
  process_inventory /var/group_variables/kni-qe-129/masters /eco-ci-cd/inventories/ocp-deployment/group_vars/masters
  process_inventory /var/host_variables/kni-qe-129/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
  process_inventory /var/host_variables/kni-qe-129/master0 /eco-ci-cd/inventories/ocp-deployment/host_vars/master0
  touch /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor
fi

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

echo "Mirroring spoke operators (VERSION=${VERSION})"
ansible-playbook ./playbooks/deploy-ocp-operators.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=${VERSION} disconnected=true mirror_only=true operators='$SPOKE_OPERATORS' ocp_operator_mirror_skip_internal_registry_cleanup=true"
