#!/bin/bash

set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
PROJECT_DIR="/tmp"

echo "Create group_vars directory"
mkdir "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Copy group inventory files"
# shellcheck disable=SC2154
cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Copy host inventory files"
cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME="${CLUSTER_NAME}"
echo CLUSTER_NAME="${CLUSTER_NAME}"

echo "Setup test script"
cd /eco-ci-cd
ansible-playbook ./playbooks/cnf/deploy-run-metric-tests-script.yaml -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Run metric tests via ssh tunnel"
ssh -o StrictHostKeyChecking=no "${BASTION_USER}"@"${BASTION_IP}" -i /tmp/temp_ssh_key "cd /tmp/network-metrics-daemon;./network-metrics-daemon-run.sh || true"

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}"@"${BASTION_IP}":/tmp/nmd_report/nmd_report.xml "${ARTIFACT_DIR}/junit_nmd_report.xml"

echo "Store report for reporter step"
# shellcheck disable=SC2154
cp "${ARTIFACT_DIR}/junit_nmd_report.xml" "${SHARED_DIR}/junit_nmd_report.xml"
