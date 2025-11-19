#!/bin/bash
set -e
set -o pipefail
MOUNTED_HOST_INVENTORY="/var/host_variables"
MOUNTED_GROUP_VARIABLES="/var/group_variables"

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
        else
          echo "$(basename "${filename}")": \'"$(cat "$filename")"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}


export CLUSTER_NAME="kni-qe-100"
echo CLUSTER_NAME="${CLUSTER_NAME}"

echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find "${MOUNTED_GROUP_VARIABLES}/${CLUSTER_NAME}/" -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done


echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

find "${MOUNTED_HOST_INVENTORY}/${CLUSTER_NAME}/" -mindepth 1 -type d | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

echo "Copy shared infrastructure inventory from SHARED_DIR"
for host in bastion hypervisor; do
    cp "${SHARED_DIR}/${host}" /eco-ci-cd/inventories/ocp-deployment/host_vars/"${host}"
done

for group in all bastions hypervisors; do
    cp "${SHARED_DIR}/${group}" /eco-ci-cd/inventories/ocp-deployment/group_vars/"${group}"
done

echo "Set up SSH key configuration for Ansible"
PROJECT_DIR="/tmp"
grep ansible_ssh_private_key -A 100 /eco-ci-cd/inventories/ocp-deployment/group_vars/all \
    | sed 's/ansible_ssh_private_key: //g' \
    | sed "s/'//g" \
    > "${PROJECT_DIR}/ansible_ssh_key"
    
chmod 600 "${PROJECT_DIR}/ansible_ssh_key"
export ANSIBLE_PRIVATE_KEY_FILE="${PROJECT_DIR}/ansible_ssh_key"
echo "SSH key configured at: ${ANSIBLE_PRIVATE_KEY_FILE}"

cd /eco-ci-cd
ansible-playbook ./playbooks/ran/create-spoke-masters.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --private-key="${ANSIBLE_PRIVATE_KEY_FILE}"

echo "Store new spoke cluster inventory in SHARED_DIR"
for host in master0 master1 master2; do
    if [ -f /eco-ci-cd/inventories/ocp-deployment/host_vars/"${host}" ]; then
        cp /eco-ci-cd/inventories/ocp-deployment/host_vars/"${host}" "${SHARED_DIR}"/
    fi
done

for group in masters nodes; do
    if [ -f /eco-ci-cd/inventories/ocp-deployment/group_vars/"${group}" ]; then
        cp /eco-ci-cd/inventories/ocp-deployment/group_vars/"${group}" "${SHARED_DIR}"/"${group}"-"${CLUSTER_NAME}"
    fi
done
