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

echo "Running ZTP deployment for sno spoke cluster: ${SPOKE_CLUSTER}"
ansible-playbook ./playbooks/ran/deploy-spoke-sno.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_clusters='${SPOKE_CLUSTER}' \
        ztp_git_repo_url=${ZTP_GIT_REPO} \
        ztp_clusters_git_path=siteconfig/${VERSION} \
        ztp_policies_git_path=policygentemplates/${VERSION} \
        ztp_git_repo_branch=${ZTP_GIT_BRANCH}"
