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
}

CLUSTER_NAME=${SPOKE_CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "Processing common group_vars"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing cluster group_vars (${CLUSTER_NAME})"
find "/var/group_variables/${CLUSTER_NAME}/" -mindepth 1 -type d | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing cluster host_vars (${CLUSTER_NAME})"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

find "${MOUNTED_HOST_INVENTORY}/${CLUSTER_NAME}/" -mindepth 1 -type d | while read -r dir; do
  echo "  host_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

# Copy Group vars from previous step
cp -r "${SHARED_DIR}"/all /eco-ci-cd/inventories/ocp-deployment/group_vars/
cp -r "${SHARED_DIR}"/bastions /eco-ci-cd/inventories/ocp-deployment/group_vars/
cp -r "${SHARED_DIR}"/hypervisors /eco-ci-cd/inventories/ocp-deployment/group_vars/

cd /eco-ci-cd
ansible-playbook -vv playbooks/ran/create-spoke-masters.yml \
  -i inventories/ocp-deployment/build-inventory.py
