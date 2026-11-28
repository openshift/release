#!/bin/bash
set +x
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  exit 0
fi

PROJECT_DIR="/tmp"
install -m 600 \
  /var/group_variables/common/all/ansible_ssh_private_key \
  "${PROJECT_DIR}/ansible_ssh_key"

export ANSIBLE_PRIVATE_KEY_FILE="${PROJECT_DIR}/ansible_ssh_key"
export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_TIMEOUT=600
export ANSIBLE_HOST_KEY_CHECKING=False

cd /eco-ci-cd
INVENTORY_PATH=./inventories/ocp-deployment
mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

for hub in seed target; do
  cluster="${CLUSTER_NAME}"
  if [[ "${hub}" == target ]]; then
    cluster="${TARGET_CLUSTER_NAME}"
  fi
  for group in all bastions; do
    cp "${SHARED_DIR}/${hub}-${group}" "${INVENTORY_PATH}/group_vars/${group}"
  done
  cp "${SHARED_DIR}/${hub}-bastion" "${INVENTORY_PATH}/host_vars/bastion"

  echo "Preparing ${hub} hub prerequisites"
  ansible-playbook ./playbooks/ran/ibi-hub-prepare.yml \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --limit bastion \
    --extra-vars "kubeconfig=/home/telcov10n/project/generated/${cluster}/auth/kubeconfig ibi_hub_role=${hub}"
done
