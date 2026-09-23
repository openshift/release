#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

process_inventory() {
  local directory="$1"
  local dest_file="$2"

  if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a valid directory"
    return 1
  fi

  find "$directory" -type f | while IFS= read -r filename; do
    if [[ $filename == *"secretsync-vault-source-path"* ]]; then
      continue
    else
      echo "$(basename "${filename}")": \'"$(cat "$filename")"\'
    fi
  done > "${dest_file}"
}

mkdir -p ${INVENTORY_PATH}/group_vars
process_inventory /var/group_variables/common/all      ${INVENTORY_PATH}/group_vars/all
process_inventory /var/group_variables/common/bastions ${INVENTORY_PATH}/group_vars/bastions

mkdir -p ${INVENTORY_PATH}/host_vars
process_inventory /var/host_variables/${CLUSTER_NAME}/bastion ${INVENTORY_PATH}/host_vars/bastion

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

echo "Pruning ArgoCD apps and removing seed ManagedCluster for spoke: ${SEED_SPOKE_CLUSTER}"
ansible-playbook playbooks/ran/ibu-prune-argocd-apps.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --extra-vars "hub_kubeconfig=${KUBECONFIG_PATH} \
    spoke_cluster=${SEED_SPOKE_CLUSTER}"
