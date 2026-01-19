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
else
  SPOKE_CLUSTER="kni-qe-100"
fi

echo "SPOKE_CLUSTER=${SPOKE_CLUSTER}"

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

echo "Process bastion host variables (from hub kni-qe-99)"
find /var/host_variables/kni-qe-99/ -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

echo "Process spoke cluster host variables"
find "/var/host_variables/${SPOKE_CLUSTER}/" -mindepth 1 -maxdepth 1 -type d ! -name '..*' 2>/dev/null | while read -r dir; do
    echo "Process host inventory file: ${dir}"
    process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"
HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/kni-qe-99"

cd /eco-ci-cd

ansible-playbook ./playbooks/cnf/deploy-run-eco-gotests.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${SPOKE_KUBECONFIG} features=deploymenttypes labels='!no-container' additional_test_env_variables='-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true' hub_clusterconfigs_path=${HUB_CLUSTERCONFIGS_PATH} eco_gotests_tag=latest"

PROJECT_DIR="/tmp"

echo "Set bastion ssh configuration"
# Read SSH key directly from vault mount (raw file, no YAML parsing needed)
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run eco-gotests via ssh tunnel"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" "cd /tmp/eco_gotests;./eco-gotests-run.sh || true"


