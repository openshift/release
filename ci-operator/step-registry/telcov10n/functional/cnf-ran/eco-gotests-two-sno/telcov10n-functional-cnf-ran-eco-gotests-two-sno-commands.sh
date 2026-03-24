#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Create group_vars directory"
mkdir -p "${INVENTORY_PATH}/group_vars"

echo "Copy group inventory files from SHARED_DIR"
cp "${SHARED_DIR}/all" "${INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir -p "${INVENTORY_PATH}/host_vars"

echo "Copy host inventory files from SHARED_DIR"
cp "${SHARED_DIR}/bastion" "${INVENTORY_PATH}/host_vars/bastion"

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

ansible-playbook -vv ./playbooks/ran/deploy-two-sno-tests-script.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "hub_kubeconfig=${KUBECONFIG_PATH}"

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
# Read SSH key directly from vault mount (raw file, no YAML parsing needed)
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

TEST_SUITES=(talm ztp deploymenttypes)

for suite in "${TEST_SUITES[@]}"; do
  remote_dir="/tmp/eco_gotests_${suite}"
  echo "Run eco-gotests ${suite} tests via ssh tunnel"
  ssh -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" \
    -i "${PROJECT_DIR}/temp_ssh_key" "cd ${remote_dir}; ./eco-gotests-run.sh || true"
done

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
for suite in "${TEST_SUITES[@]}"; do
  remote_dir="/tmp/eco_gotests_${suite}"
  artifact_dir="${ARTIFACT_DIR}/junit_eco_gotests_${suite}"
  mkdir -p "${artifact_dir}"
  scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:${remote_dir}/report/*.xml" "${artifact_dir}/"
done

rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Store Polarion report for reporter step"
for suite in "${TEST_SUITES[@]}"; do
  artifact_dir="${ARTIFACT_DIR}/junit_eco_gotests_${suite}"
  if [ -f "${artifact_dir}/report_testrun.xml" ]; then
    mv "${artifact_dir}/report_testrun.xml" "${SHARED_DIR}/polarion_testrun_${suite}.xml"
    cp "${SHARED_DIR}/polarion_testrun_${suite}.xml" "${SHARED_DIR}/junit_${suite}_suite_test_junit.xml"
  fi
done
