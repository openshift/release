#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        fi
        local content
        content=$(cat "$filename")
        local varname
        varname=$(basename "${filename}")
        # Check if content has newlines - if so, use literal block scalar (|)
        if [[ "$content" == *$'\n'* ]]; then
          echo "${varname}: |"
          # Indent each line with 2 spaces for YAML block scalar
          echo "$content" | sed 's/^/  /'
        else
          echo "${varname}": \'"${content}"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

echo "Create group_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Process common group variables (all, bastions)"
find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Create host_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files from SHARED_DIR (populated by hub-deploy step)"
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
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/ansible_ssh_key"
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

# Substitute VERSION_TAG in HUB_OPERATORS variable for TALM operator configuration
HUB_OPERATORS=$(echo "${HUB_OPERATORS}" | sed "s/\${VERSION_TAG}/${VERSION_TAG}/g")
echo "HUB_OPERATORS after substitution: ${HUB_OPERATORS}"

export ANSIBLE_HOST_KEY_CHECKING=False
# deploy ztp operators (acm, lso, gitops)

cd /eco-ci-cd/

ansible-playbook ./playbooks/deploy-ocp-operators.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=$VERSION disconnected=$DISCONNECTED operators='$HUB_OPERATORS'"

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


