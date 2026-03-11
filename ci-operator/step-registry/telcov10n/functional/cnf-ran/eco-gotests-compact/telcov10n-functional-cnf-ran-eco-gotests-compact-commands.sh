#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

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
        fi
        local content
        content=$(cat "$filename")
        local varname
        varname=$(basename "${filename}")
        # Check if content has newlines - if so, use literal block scalar (|)
        if [[ "$content" == *$'\n'* ]]; then
          echo "${varname}: |"
          echo "$content" | sed 's/^/  /'
        else
          echo "${varname}": \'"${content}"\'
        fi
    done > "${dest_file}"

    echo "Processing complete. Check \"${dest_file}\""
}

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
  --extra-vars "kubeconfig=${SPOKE_KUBECONFIG} features=deploymenttypes labels='!no-container' additional_test_env_variables='-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true' hub_clusterconfigs_path=${HUB_CLUSTERCONFIGS_PATH} eco_gotests_tag=latest" \
  --extra-vars "eco_cnf_core_net_switch_user='' eco_cnf_core_net_switch_pass='' eco_worker_label=''"

PROJECT_DIR="/tmp"

echo "Set bastion ssh configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run eco-gotests via ssh tunnel"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" "cd /tmp/eco_gotests;./eco-gotests-run.sh || true"

echo "Create artifact directory for reports"
mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests/"

echo "Gather ALL reports from bastion (all files are in report directory before separation)"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key" "${BASTION_USER}@${BASTION_IP}":/tmp/eco_gotests/report/*.xml "${ARTIFACT_DIR}/junit_eco_gotests/" 2>/dev/null || true

echo "Copy reports to SHARED_DIR with prefixes (SHARED_DIR only supports files, not directories)"
# Polarion reports: prefix with 'polarion_'
for f in "${ARTIFACT_DIR}"/junit_eco_gotests/report_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying polarion report: $filename -> polarion_${filename}"
    cp "$f" "${SHARED_DIR}/polarion_${filename}"
  fi
done

# Junit reports: prefix with 'junit_'
for f in "${ARTIFACT_DIR}"/junit_eco_gotests/*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    if [[ "$filename" == *junit*.xml ]] || [[ "$filename" == *_suite_*.xml ]]; then
      if [[ "$filename" != report_*.xml ]]; then
        echo "Copying junit report: $filename -> junit_${filename}"
        cp "$f" "${SHARED_DIR}/junit_${filename}"
      fi
    fi
  fi
done

rm -rf "${PROJECT_DIR}/temp_ssh_key"
