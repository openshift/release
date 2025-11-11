#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi


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

# Configure Ansible SSH settings for connection resilience
export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_SSH_ARGS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=30"
export ANSIBLE_TIMEOUT=600

# Create VERSION_TAG for TALM operator by replacing dots with dashes
# Example: VERSION="4.19" becomes VERSION_TAG="4-19"
VERSION_TAG=$(echo "${VERSION}" | tr '.' '-')
export VERSION_TAG
echo "VERSION_TAG=${VERSION_TAG}"

# Substitute VERSION_TAG in OPERATORS variable for TALM operator configuration
OPERATORS=$(echo "${OPERATORS}" | envsubst '${VERSION_TAG}')
echo "OPERATORS after substitution: ${OPERATORS}"

export ANSIBLE_HOST_KEY_CHECKING=False
# deploy ztp operators (acm, lso, gitops)

cd /eco-ci-cd/

cat <<EOF > ansible.cfg
    [defaults]
    collections_path = ./collections
    host_key_checking = False
    force_color = True
    roles_path = ./playbooks/compute/nto/roles:./playbooks/infra/roles
    [ssh_connection]
    ssh_args = -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no 
    EOF
cat ansible.cfg

ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=$VERSION disconnected=$DISCONNECTED operators='$OPERATORS'"

# configure lso 
ansible-playbook playbooks/ran/configure-lvm-storage.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH}" -vv

# configure acm
ansible-playbook playbooks/ran/configure-acm.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

# configure kustomize plugin
ansible-playbook playbooks/ran/configure-kustomize-plugin.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=v$VERSION" -vv


