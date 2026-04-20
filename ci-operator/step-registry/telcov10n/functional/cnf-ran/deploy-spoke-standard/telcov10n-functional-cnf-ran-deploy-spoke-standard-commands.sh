#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

echo "Deploying spoke standard cluster: ${SPOKE_CLUSTER}"

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

echo "Processing common group_vars"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing spoke group_vars (${SPOKE_CLUSTER})"
find "/var/group_variables/${SPOKE_CLUSTER}/" -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing hub host_vars (kni-qe-99)"
mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

find /var/host_variables/kni-qe-99/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  host_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

if [ -d "/var/host_variables/${SPOKE_CLUSTER}/" ]; then
  echo "Processing spoke host_vars (${SPOKE_CLUSTER})"
  find "/var/host_variables/${SPOKE_CLUSTER}/" -mindepth 1 -type d | while read -r dir; do
    echo "  host_var: $(basename "${dir}")"
    process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
  done
else
  echo "No spoke host_vars found for ${SPOKE_CLUSTER} — skipping"
fi

KUBECONFIG_PATH="/home/telcov10n/project/generated/kni-qe-99/auth/kubeconfig"

export HOME=/tmp
mkdir -p /tmp/.ansible/tmp

cat > /tmp/ansible.cfg << 'EOF'
[defaults]
local_tmp = /tmp/.ansible/tmp
remote_tmp = /tmp/.ansible/tmp
collections_path = /eco-ci-cd/collections
host_key_checking = False

[ssh_connection]
ssh_args = "-o UserKnownHostsFile=/dev/null"
EOF
export ANSIBLE_CONFIG=/tmp/ansible.cfg

cd /eco-ci-cd

echo "Running ansible-playbook deploy-spoke-ztp for ${SPOKE_CLUSTER}"
ansible-playbook -i inventories/ocp-deployment/build-inventory.py \
  playbooks/ran/deploy-spoke-ztp.yml \
  -e ansible_remote_tmp=/tmp/.ansible/tmp \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    bmc_secret_name=${BMC_SECRET_NAME} \
    spoke_cluster=${SPOKE_CLUSTER} \
    masters_secret_name=${MASTERS_SECRET_NAME} \
    ocp_version=${VERSION} \
    ztp_git_repo_url=${ZTP_GIT_REPO} \
    ztp_git_branch=${ZTP_GIT_BRANCH}"
