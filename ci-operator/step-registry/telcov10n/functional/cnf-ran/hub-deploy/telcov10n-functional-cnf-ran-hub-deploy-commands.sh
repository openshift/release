#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

MOUNTED_HOST_INVENTORY="/var/host_variables"

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
        else
          echo "$(basename "${filename}")": \'"$(cat "$filename")"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}


export CLUSTER_NAME="kni-qe-99"
echo CLUSTER_NAME="${CLUSTER_NAME}"

echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

find /var/group_variables/"${CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars


find ${MOUNTED_HOST_INVENTORY}/"${CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

cd /eco-ci-cd
ansible-playbook ./playbooks/deploy-ocp-sno.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "release=${VERSION} cluster_name=${CLUSTER_NAME} disconnected=true"

echo "Store inventory in SHARED_DIR"
cp -r /eco-ci-cd/inventories/ocp-deployment/host_vars/* "${SHARED_DIR}"/
cp -r /eco-ci-cd/inventories/ocp-deployment/group_vars/* "${SHARED_DIR}"/

echo "Getting cluster version from hub cluster"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' /eco-ci-cd/inventories/ocp-deployment/group_vars/all | sed "s/'//g")

cat /var/group_variables/common/all/ansible_ssh_private_key > "/tmp/temp_ssh_key"
chmod 600 "/tmp/temp_ssh_key"

CLUSTER_VERSION=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}" \
  "KUBECONFIG=${HUB_KUBECONFIG} oc get clusterversion version -ojsonpath='{.status.desired.version}'")

echo "Cluster version: ${CLUSTER_VERSION}"
echo "${CLUSTER_VERSION}" > "${SHARED_DIR}/cluster_version"
