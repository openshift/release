#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
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

echo "Create group_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

echo "Copy group inventory files from SHARED_DIR"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
cp ${SHARED_DIR}/hypervisors /eco-ci-cd/inventories/ocp-deployment/group_vars/hypervisors
cp ${SHARED_DIR}/nodes /eco-ci-cd/inventories/ocp-deployment/group_vars/nodes
cp ${SHARED_DIR}/masters /eco-ci-cd/inventories/ocp-deployment/group_vars/masters

echo "Create host_vars directory"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

echo "Copy host inventory files from SHARED_DIR"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp ${SHARED_DIR}/hypervisor /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor

echo "Deploy spoke master VMs for seed hub (${SEED_CLUSTER_NAME})"
process_inventory "${MOUNTED_HOST_INVENTORY}/${SEED_CLUSTER_NAME}/spoke-master0" \
  /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

cd /eco-ci-cd
ansible-playbook playbooks/ran/create-spoke-masters.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --private-key=~/.ssh/ansible_ssh_private_key -vv

echo "Remove seed master0 from host_vars"
rm -f /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

echo "Deploy spoke master VMs for target hub (${TARGET_CLUSTER_NAME})"
process_inventory "${MOUNTED_HOST_INVENTORY}/${TARGET_CLUSTER_NAME}/spoke-master0" \
  /eco-ci-cd/inventories/ocp-deployment/host_vars/master0

cd /eco-ci-cd
ansible-playbook playbooks/ran/create-spoke-masters.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --private-key=~/.ssh/ansible_ssh_private_key -vv
