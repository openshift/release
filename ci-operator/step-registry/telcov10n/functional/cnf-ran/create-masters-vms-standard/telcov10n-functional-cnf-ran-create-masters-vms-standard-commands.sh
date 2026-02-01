#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

MOUNTED_HOST_INVENTORY="/var/host_variables"

echo "Creating master VMs for spoke cluster: ${SPOKE_CLUSTER}"

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

echo "Create group_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files from SHARED_DIR"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp ${SHARED_DIR}/hypervisors /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
cp ${SHARED_DIR}/nodes /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes

echo "Process mounted group variables for ${SPOKE_CLUSTER}"
find "/var/group_variables/${SPOKE_CLUSTER}/" -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Create host_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files from SHARED_DIR"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp ${SHARED_DIR}/hypervisor /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor

echo "Process mounted host variables for ${SPOKE_CLUSTER}"
find "${MOUNTED_HOST_INVENTORY}/${SPOKE_CLUSTER}/" -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

cd /eco-ci-cd
ansible-playbook playbooks/ran/create-spoke-masters.yml -i inventories/ocp-deployment/build-inventory.py \
 --private-key=~/.ssh/ansible_ssh_private_key -vv
