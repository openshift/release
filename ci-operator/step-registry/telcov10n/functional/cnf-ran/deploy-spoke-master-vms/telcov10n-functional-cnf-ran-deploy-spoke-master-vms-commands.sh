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

echo "SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME}"

echo "Processing group_vars"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find "/var/group_variables/${SPOKE_CLUSTER_NAME}/" -mindepth 1 -type d | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing host_vars"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

find ${MOUNTED_HOST_INVENTORY}/"${SPOKE_CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

# # spoke cluster 131 uses hub bastion kni-qe-130
# if [[ "${CLUSTER_NAME}"  == "kni-qe-131" ]]; then
#   echo "Processing shared bastion inventory for ${CLUSTER_NAME}"
#   process_inventory "${MOUNTED_HOST_INVENTORY}/kni-qe-130/bastion" \
#     /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
# fi

echo "Copy host inventory files from SHARED_DIR"
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp ${SHARED_DIR}/hypervisor /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor

# TODO: delete this 
# echo "Deploy spoke master VMs for target hub (${TARGET_CLUSTER_NAME})"
# process_inventory "${MOUNTED_HOST_INVENTORY}/${TARGET_CLUSTER_NAME}/spoke-master0" \
#   /eco-ci-cd/inventories/ocp-deployment/host_vars/master0


cd /eco-ci-cd
ansible-playbook playbooks/ran/create-spoke-masters.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --private-key=~/.ssh/ansible_ssh_private_key -vv
