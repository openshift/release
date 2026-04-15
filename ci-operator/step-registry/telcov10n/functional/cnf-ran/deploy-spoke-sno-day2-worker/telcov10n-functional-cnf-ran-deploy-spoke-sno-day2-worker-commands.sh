#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Create group_vars directory"
mkdir -p ${INVENTORY_PATH}/group_vars

echo "Copy group inventory files from SHARED_DIR"
cp ${SHARED_DIR}/all ${INVENTORY_PATH}/group_vars/all
cp ${SHARED_DIR}/bastions ${INVENTORY_PATH}/group_vars/bastions
cp ${SHARED_DIR}/hypervisors ${INVENTORY_PATH}/group_vars/hypervisors
cp ${SHARED_DIR}/nodes ${INVENTORY_PATH}/group_vars/nodes
cp ${SHARED_DIR}/masters ${INVENTORY_PATH}/group_vars/masters

echo "Create host_vars directory"
mkdir -p ${INVENTORY_PATH}/host_vars

echo "Copy host inventory files from SHARED_DIR"
cp ${SHARED_DIR}/bastion ${INVENTORY_PATH}/host_vars/bastion
cp ${SHARED_DIR}/hypervisor ${INVENTORY_PATH}/host_vars/hypervisor
cp ${SHARED_DIR}/master0 ${INVENTORY_PATH}/host_vars/master0

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

# Parse first spoke cluster name from array format, e.g. "['kni-qe-107']" → "kni-qe-107"
SPOKE_CLUSTER_NAME=$(echo "${SPOKE_CLUSTER}" | tr -d "[]' ")

echo "Running day 2 worker expansion for SNO spoke cluster: ${SPOKE_CLUSTER_NAME}"
ansible-playbook ./playbooks/deploy-ocp-sno-day2-worker.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_cluster_name=${SPOKE_CLUSTER_NAME} \
        day2_branch=${ZTP_GIT_BRANCH_DAY2_WORKER} \
        disconnected=${DISCONNECTED}"
