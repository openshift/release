#!/bin/bash
set -e
set -o pipefail

# TODO: Remove this line once the step is integrated into the workflow
# This is a temporary workaround for testing the cleanup step in isolation
echo "kni-qe-100" > "${SHARED_DIR}/spoke_cluster"

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

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
          # SSH key needs YAML block format for multi-line content
          echo -e "$(basename "${filename}")": \|"\n$(sed 's/^/  /' "${filename}")"
        else
          echo "$(basename "${filename}")": \'"$(cat "$filename")"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

if [[ -f "${SHARED_DIR}/spoke_cluster" ]]; then
  SPOKE_CLUSTER="$(cat "${SHARED_DIR}/spoke_cluster")"
fi

echo "SPOKE_CLUSTER=${SPOKE_CLUSTER}"
echo "HUB_CLUSTER=${HUB_CLUSTER}"

echo "Create group_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Process common group variables (all, bastions)"
find /var/group_variables/common/ -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/$(basename "${dir}")"
done

echo "Process spoke cluster group variables"
find "/var/group_variables/${SPOKE_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/$(basename "${dir}")"
done

echo "Create host_vars directory"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Process bastion host variables (from hub ${HUB_CLUSTER})"
find "/var/host_variables/${HUB_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

echo "Process spoke cluster host variables"
find "/var/host_variables/${SPOKE_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

HUB_KUBECONFIG="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

cd /eco-ci-cd

echo "Running spoke cleanup for ${SPOKE_CLUSTER}"
ansible-playbook playbooks/ran/spoke_cleanup.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  --extra-vars "hub_kubeconfig=${HUB_KUBECONFIG} spoke_cluster=${SPOKE_CLUSTER}"
