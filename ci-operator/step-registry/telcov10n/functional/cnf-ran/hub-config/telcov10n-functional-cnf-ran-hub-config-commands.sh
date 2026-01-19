#!/bin/bash
set -e
set -o pipefail


echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions

echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp ${SHARED_DIR}/master0 /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME="kni-qe-99"
echo CLUSTER_NAME=${CLUSTER_NAME}

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/kni-qe-99/auth/kubeconfig"

# Extract and configure SSH key for Ansible to connect to masters
echo "Set up SSH key configuration for Ansible"
PROJECT_DIR="/tmp"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/ansible_ssh_key"
chmod 600 "${PROJECT_DIR}/ansible_ssh_key"
export ANSIBLE_PRIVATE_KEY_FILE="${PROJECT_DIR}/ansible_ssh_key"
echo "SSH key configured at: ${ANSIBLE_PRIVATE_KEY_FILE}"

# Configure Ansible SSH settings for connection resilience
export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_TIMEOUT=600

# Create VERSION_TAG for TALM operator by replacing dots with dashes
# Example: VERSION="4.19" becomes VERSION_TAG="4-19"
VERSION_TAG=$(echo "${VERSION}" | tr '.' '-')
export VERSION_TAG
echo "VERSION_TAG=${VERSION_TAG}"

# Substitute VERSION_TAG in OPERATORS variable for TALM operator configuration
OPERATORS=$(echo "${OPERATORS}" | sed "s/\${VERSION_TAG}/${VERSION_TAG}/g")
echo "OPERATORS after substitution: ${OPERATORS}"

export ANSIBLE_HOST_KEY_CHECKING=False
# deploy ztp operators (acm, lso, gitops)

cd /eco-ci-cd/

ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=$VERSION disconnected=$DISCONNECTED operators='$OPERATORS'"

# configure lso 
ansible-playbook playbooks/ran/hub-sno-configure-lvm-storage.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --private-key="${PROJECT_DIR}/ansible_ssh_key" \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH}" -vv

# configure acm
ansible-playbook playbooks/ran/hub-sno-configure-acm.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

# configure kustomize plugin
ansible-playbook playbooks/ran/hub-sno-configure-kustomize-plugin.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

# configure gitops
ansible-playbook playbooks/ran/hub-sno-configure-gitops.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} gitlab_repo_url=${GITLAB_REPO_URL}" -vv


