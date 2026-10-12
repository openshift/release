#!/bin/bash
set -e
set -o pipefail

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

# copy inventory to shared dir
mkdir ${INVENTORY_PATH}/group_vars
cp -r "${SHARED_DIR}"/all ${INVENTORY_PATH}/group_vars/
cp -r "${SHARED_DIR}"/bastions ${INVENTORY_PATH}/group_vars/
cp -r "${SHARED_DIR}"/hypervisors ${INVENTORY_PATH}/group_vars/

mkdir ${INVENTORY_PATH}/host_vars
cp -r "${SHARED_DIR}"/bastion ${INVENTORY_PATH}/host_vars/
cp -r "${SHARED_DIR}"/hypervisor ${INVENTORY_PATH}/host_vars/
cp -r "${SHARED_DIR}"/master* ${INVENTORY_PATH}/host_vars/
cp -r "${SHARED_DIR}"/worker* ${INVENTORY_PATH}/host_vars/

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Running ZTP deployment for spoke cluster: ${SPOKE_CLUSTER_NAME}"
ansible-playbook ./playbooks/ran/deploy-spoke-ztp-mno.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_cluster=${SPOKE_CLUSTER_NAME} \
        ocp_version=${VERSION} \
        arch=${SPOKE_ARCH} \
        ztp_git_repo_url=${GITLAB_REPO_URL} \
        ztp_git_branch=${ZTP_GIT_BRANCH}"
