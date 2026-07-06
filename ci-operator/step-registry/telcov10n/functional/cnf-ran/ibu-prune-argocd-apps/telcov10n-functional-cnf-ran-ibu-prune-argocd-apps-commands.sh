#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

mkdir -p ${INVENTORY_PATH}/group_vars
cp ${SHARED_DIR}/all ${INVENTORY_PATH}/group_vars/all
cp ${SHARED_DIR}/bastions ${INVENTORY_PATH}/group_vars/bastions

mkdir -p ${INVENTORY_PATH}/host_vars
cp ${SHARED_DIR}/bastion ${INVENTORY_PATH}/host_vars/bastion

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

echo "Pruning ArgoCD apps and removing seed ManagedCluster for spoke: ${SPOKE_CLUSTER}"
ansible-playbook playbooks/ran/ibu-prune-argocd-apps.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --extra-vars "hub_kubeconfig=${KUBECONFIG_PATH} \
    spoke_cluster=${SPOKE_CLUSTER}"
