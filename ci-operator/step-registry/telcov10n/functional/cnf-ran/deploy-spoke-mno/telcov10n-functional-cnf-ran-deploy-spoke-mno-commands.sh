#!/bin/bash
set -e
set -o pipefail

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
tar -xzvf "${SHARED_DIR}/inventory.tar.gz" -C "${INVENTORY_PATH}"

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Running ZTP deployment for spoke cluster: ${SPOKE_CLUSTER_NAME}"
ansible-playbook ./playbooks/ran/deploy-spoke-ztp-mno.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_clusters='${SPOKE_CLUSTER_NAME}' \
        ocp_version=${VERSION} \
        arch=${SPOKE_ARCH} \
        ztp_git_repo_url=${GITLAB_REPO_URL} \
        ztp_git_repo_branch=${ZTP_GIT_BRANCH}"
