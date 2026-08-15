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

echo "Copy target hub group inventory files from SHARED_DIR (target- prefixed)"
cp ${SHARED_DIR}/target-all ${INVENTORY_PATH}/group_vars/all
cp ${SHARED_DIR}/target-bastions ${INVENTORY_PATH}/group_vars/bastions
cp ${SHARED_DIR}/target-hypervisors ${INVENTORY_PATH}/group_vars/hypervisors
cp ${SHARED_DIR}/target-nodes ${INVENTORY_PATH}/group_vars/nodes
cp ${SHARED_DIR}/target-masters ${INVENTORY_PATH}/group_vars/masters

echo "Create host_vars directory"
mkdir -p ${INVENTORY_PATH}/host_vars

echo "Copy target hub host inventory files from SHARED_DIR (target- prefixed)"
cp ${SHARED_DIR}/target-bastion ${INVENTORY_PATH}/host_vars/bastion
cp ${SHARED_DIR}/target-hypervisor ${INVENTORY_PATH}/host_vars/hypervisor
cp ${SHARED_DIR}/target-master0 ${INVENTORY_PATH}/host_vars/master0

# Kubeconfig lives on the target hub bastion, under the target cluster name
KUBECONFIG_PATH="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

echo "Running ZTP deployment for target SNO spoke cluster: ${TARGET_SPOKE_CLUSTER}"
ansible-playbook ./playbooks/ran/deploy-spoke-sno.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_clusters='${TARGET_SPOKE_CLUSTER}' \
        ztp_git_repo_url=${ZTP_GIT_REPO} \
        ztp_clusters_git_path=siteconfig/${TARGET_SPOKE_VERSION} \
        ztp_policies_git_path=policygentemplates/${TARGET_SPOKE_VERSION} \
        ztp_git_repo_branch=${ZTP_GIT_BRANCH}"
