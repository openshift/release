#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

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
        elif [[ $filename == *"ansible_ssh_private_key"* ]]; then
          echo -e "$(basename ${filename})": \|"\n$(cat $filename | sed 's/^/  /')"
        else
          echo "$(basename ${filename})": \'"$(cat $filename)"\'
        fi
    done > $dest_file

    echo "Processing complete. Check ${dest_file}"
}

echo "Create group_vars directory"
mkdir ${ECO_CI_CD_INVENTORY_PATH}/group_vars

find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir ${ECO_CI_CD_INVENTORY_PATH}/group_vars/"$(basename ${dir})"
done

echo "Create host_vars directory"
mkdir ${ECO_CI_CD_INVENTORY_PATH}/host_vars

find /var/host_variables/${CLUSTER_NAME}/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir ${ECO_CI_CD_INVENTORY_PATH}/host_vars/"$(basename ${dir})"
done

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo CLUSTER_NAME=${CLUSTER_NAME}

echo "Set OCP_NIC env var"
if [[ -f "${SHARED_DIR}/ocp_nic" ]]; then
    OCP_NIC=$(cat "${SHARED_DIR}/ocp_nic")
fi
export OCP_NIC=${OCP_NIC}
echo OCP_NIC=${OCP_NIC}

echo "Set SECONDARY_NIC env var"
if [[ -f "${SHARED_DIR}/secondary_nic" ]]; then
    SECONDARY_NIC=$(cat "${SHARED_DIR}/secondary_nic")
fi
export SECONDARY_NIC=${SECONDARY_NIC}
echo SECONDARY_NIC=${SECONDARY_NIC}

cd /eco-ci-cd/

export ANSIBLE_REMOTE_TEMP="/tmp"
ansible-playbook ./playbooks/cnf/switch-config.yaml -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "cluster_name=$CLUSTER_NAME artifact_dest_dir=$SHARED_DIR ocp_nic=$OCP_NIC secondary_nic=$SECONDARY_NIC"

cp ${ECO_CI_CD_INVENTORY_PATH}/host_vars/switch ${SHARED_DIR}/
