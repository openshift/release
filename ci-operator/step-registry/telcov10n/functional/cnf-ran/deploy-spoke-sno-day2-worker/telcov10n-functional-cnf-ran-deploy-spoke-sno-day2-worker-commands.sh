#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
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

echo "CLUSTER_NAME=${CLUSTER_NAME}"

if [ "${CLUSTER_NAME}" != "kni-qe-106" ]; then
    echo "ERROR: Only CLUSTER_NAME=kni-qe-106 is supported by this step."
    echo "This step mounts credentials specific to the kni-qe-106 hub."
    exit 1
fi

echo "Create group_vars directory"
mkdir -p ${INVENTORY_PATH}/group_vars

echo "Process common group variables (all, bastions, hypervisors)"
find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" ${INVENTORY_PATH}/group_vars/"$(basename "${dir}")"
done

echo "Process cluster group variables for ${CLUSTER_NAME}"
find "/var/group_variables/${CLUSTER_NAME}/" -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" ${INVENTORY_PATH}/group_vars/"$(basename "${dir}")"
done

echo "Create host_vars directory"
mkdir -p ${INVENTORY_PATH}/host_vars

echo "Process host variables for ${CLUSTER_NAME}"
find ${MOUNTED_HOST_INVENTORY}/"${CLUSTER_NAME}"/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" ${INVENTORY_PATH}/host_vars/"$(basename "${dir}")"
done

# Workaround: fthub-01 and kni-qe-106 share the same hypervisor (hv16), but
# ci-operator cannot mount the same secret twice. Process the fthub-01 mount
# as the kni-qe-106 hypervisor inventory.
if [ "${CLUSTER_NAME}" = "kni-qe-106" ]; then
    echo "Process shared hypervisor inventory for kni-qe-106 from fthub-01 mount"
    process_inventory "${MOUNTED_HOST_INVENTORY}/fthub-01/hypervisor" \
        ${INVENTORY_PATH}/host_vars/hypervisor
fi

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

# Parse first spoke cluster name from array format, e.g. "['kni-qe-107']" → "kni-qe-107"
SPOKE_CLUSTER_NAME=$(echo "${SPOKE_CLUSTER}" | tr -d "[]' ")

echo "Running day 2 worker expansion for SNO spoke cluster: ${SPOKE_CLUSTER_NAME}"
ansible-playbook ./playbooks/deploy-ocp-sno-day2-worker.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_cluster_name=${SPOKE_CLUSTER_NAME} \
        day2_branch=${ZTP_GIT_BRANCH_DAY2_WORKER}"
