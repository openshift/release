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

# Parse first spoke cluster name from array format, e.g. "['kni-qe-107']" -> "kni-qe-107"
SPOKE_CLUSTER_NAME=$(echo "${SPOKE_CLUSTER}" | tr -d "[]' ")

# Derive spoke kubeconfig path on the bastion
SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER_NAME}-kubeconfig"

CNF_TESTS_FEATURES_LIST=(${CNF_TESTS_FEATURES})

cd /eco-ci-cd

for feature in "${CNF_TESTS_FEATURES_LIST[@]}"; do
  TESTS_SCRIPT_PATH="/tmp/cnf_gotests_${feature}"

  echo "Preparing cnf-tests for feature: ${feature}"
  ansible-playbook -vv ./playbooks/cnf/deploy-run-cnf-tests-script.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    -e "cnf_test_dir=${TESTS_SCRIPT_PATH}" \
    -e "kubeconfig=${SPOKE_KUBECONFIG}" \
    -e "features=${feature}" \
    -e "labels=${CNF_TESTS_LABELS}" \
    -e "additional_test_env_variables="
done

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
# Read SSH key directly from vault mount (raw file, no YAML parsing needed)
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

for feature in "${CNF_TESTS_FEATURES_LIST[@]}"; do
  remote_dir="/tmp/cnf_gotests_${feature}"
  echo "Run cnf-tests ${feature} tests via ssh tunnel"
  ssh -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" \
    -i "${PROJECT_DIR}/temp_ssh_key" "cd ${remote_dir}/cnf-features-deploy; ./cnf-tests-run.sh || true"
done

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
for feature in "${CNF_TESTS_FEATURES_LIST[@]}"; do
  artifact_dir="${ARTIFACT_DIR}/junit_cnf_gotests_${feature}"
  mkdir -p "${artifact_dir}"
  scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/junit/*.xml" "${artifact_dir}/" || true
done

rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Store Polarion report for reporter step"
for feature in "${CNF_TESTS_FEATURES_LIST[@]}"; do
  artifact_dir="${ARTIFACT_DIR}/junit_cnf_gotests_${feature}"
  if [ -f "${artifact_dir}/report_testrun.xml" ]; then
    mv "${artifact_dir}/report_testrun.xml" "${SHARED_DIR}/polarion_testrun_cnf_${feature}.xml"
    cp "${SHARED_DIR}/polarion_testrun_cnf_${feature}.xml" "${SHARED_DIR}/junit_cnf_${feature}_suite_test_junit.xml"
  fi
done
