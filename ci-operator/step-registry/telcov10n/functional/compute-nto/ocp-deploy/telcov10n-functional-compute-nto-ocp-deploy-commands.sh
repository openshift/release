#!/bin/bash
set -e
set -o pipefail
set -x
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

main() {

    echo "Set CLUSTER_NAME env var"
    if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
        CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
    fi
    export CLUSTER_NAME=${CLUSTER_NAME}
    echo CLUSTER_NAME="${CLUSTER_NAME}"

    echo "Create group_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

    find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    find /var/group_variables/"${CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    echo "Create host_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

    mkdir /tmp/"${CLUSTER_NAME}"
    cp -r "${MOUNTED_HOST_INVENTORY}/${CLUSTER_NAME}/hypervisor" /tmp/"${CLUSTER_NAME}"/hypervisor
    cp -r "${MOUNTED_HOST_INVENTORY}/${CLUSTER_NAME}/"* /tmp/"${CLUSTER_NAME}"/
    ls -l /tmp/"${CLUSTER_NAME}"/
    MOUNTED_HOST_INVENTORY="/tmp"

    find ${MOUNTED_HOST_INVENTORY}/"${CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
    done

    cd /eco-ci-cd
    echo "Deploy OCP for compute-nto testing"
    ansible-playbook ./playbooks/deploy-ocp-hybrid-multinode.yml -i ./inventories/ocp-deployment/build-inventory.py \
        --extra-vars "release=${VERSION} cluster_name=${CLUSTER_NAME} kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

    echo "Store inventory in SHARED_DIR"
    cp -r /eco-ci-cd/inventories/ocp-deployment/host_vars/* "${SHARED_DIR}"/
    cp -r /eco-ci-cd/inventories/ocp-deployment/group_vars/* "${SHARED_DIR}"/
}

main
