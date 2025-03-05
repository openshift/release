#!/bin/bash
set -e
set -o pipefail

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
          echo "$(basename ${filename})": \'"$(cat $filename)"\'
        fi
    done > $dest_file

    echo "Processing complete. Check ${dest_file}"
}

echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename ${dir})"
done

find /var/group_variables/${CLUSTER_NAME}/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename ${dir})"
done

echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

find /var/host_variables/${CLUSTER_NAME}/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename ${dir})"
done

cd /eco-ci-cd
ansible-playbook ./playbooks/deploy-ocp-hybrid-multinode.yml -i ./inventories/ocp-deployment/deploy-ocp-hybrid-multinode.yml --extra-vars "release=${VERSION} cluster_name=${CLUSTER_NAME}"
