#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp "${SHARED_DIR}/hypervisors" /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
cp "${SHARED_DIR}/nodes" /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes
cp "${SHARED_DIR}/masters" /eco-ci-cd/inventories/ocp-deployment/group_vars/masters

mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp "${SHARED_DIR}/hypervisor" /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor
cp "${SHARED_DIR}/master0" /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "TARGET_SPOKE_VERSION=${TARGET_SPOKE_VERSION}"

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

# Mirror seed operators first so the target mirror runs last,
echo "Mirroring seed spoke operators (VERSION=${VERSION})"
ansible-playbook ./playbooks/deploy-ocp-operators.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=${VERSION} disconnected=true mirror_only=true operators='$SPOKE_OPERATORS' ocp_operator_mirror_skip_internal_registry_cleanup=true"

echo "Mirroring target spoke operators (VERSION=${TARGET_SPOKE_VERSION})"
ansible-playbook ./playbooks/deploy-ocp-operators.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=${TARGET_SPOKE_VERSION} disconnected=true mirror_only=true operators='$TARGET_SPOKE_OPERATORS' ocp_operator_mirror_skip_internal_registry_cleanup=true"
