#!/bin/bash
set -e
set -o pipefail
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

    # Clear destination file first
    : > "${dest_file}"

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
            continue
        fi

        local key
        local value
        key=$(basename "${filename}")
        value=$(cat "$filename")

        # Handle multi-line values (e.g., certificates) with YAML literal block scalar
        if [[ "$value" == *$'\n'* ]]; then
            echo "${key}: |" >> "${dest_file}"
            while IFS= read -r line; do
                echo "  ${line}" >> "${dest_file}"
            done <<< "$value"
        else
            echo "${key}: '${value}'" >> "${dest_file}"
        fi
    done

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
