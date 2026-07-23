#!/bin/bash
set -e
set -o pipefail
set -x
MOUNTED_HOST_INVENTORY="/var/host_variables"

function copy_to_shared_dir() {
	if [ -z "$1" ]
	then
		echo "missing directory to copy"
		exit 1
	fi

	echo "copying files to $1..."
	for filename in $1/*; do cp $filename "${SHARED_DIR}/$(basename $1)_$(basename $filename)"; done

}


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
    mkdir -pv /eco-ci-cd/inventories/ocp-deployment/group_vars

    find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    find /var/group_variables/"${CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    echo "Create host_vars directory"
    mkdir -pv /eco-ci-cd/inventories/ocp-deployment/host_vars

    mkdir -pv /tmp/"${CLUSTER_NAME}"
    cp -r "${MOUNTED_HOST_INVENTORY}/${CLUSTER_NAME}/hypervisor" /tmp/"${CLUSTER_NAME}"/hypervisor
    cp -r "${MOUNTED_HOST_INVENTORY}/${CLUSTER_NAME}/"* /tmp/"${CLUSTER_NAME}"/
    ls -l /tmp/"${CLUSTER_NAME}"/
    MOUNTED_HOST_INVENTORY="/tmp"

    find ${MOUNTED_HOST_INVENTORY}/"${CLUSTER_NAME}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
    done

    echo "Store inventory in SHARED_DIR"
    copy_to_shared_dir /eco-ci-cd/inventories/ocp-deployment/host_vars
    copy_to_shared_dir /eco-ci-cd/inventories/ocp-deployment/group_vars

    echo "Flag process-inventory as completed"
    touch "${SHARED_DIR}/process-inventory-completed"
}

main
