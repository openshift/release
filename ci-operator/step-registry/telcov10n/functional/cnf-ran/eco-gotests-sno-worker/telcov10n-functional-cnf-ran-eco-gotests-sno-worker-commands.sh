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

# Parse first spoke cluster name from array format, e.g. "['kni-qe-107']" → "kni-qe-107"
SPOKE_CLUSTER_NAME=$(echo "${SPOKE_CLUSTER}" | tr -d "[]' ")

# Derive paths on the bastion
HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}"
SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER_NAME}-kubeconfig"

# Set mirror registry for disconnected environments
MIRROR_REGISTRY=""
if [ "${DISCONNECTED}" = "true" ]; then
  MIRROR_REGISTRY="disconnected.registry.local:5000"
fi

ADDITIONAL_TEST_ENV_VARS="\
-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true \
-e ECO_TEST_LABELS='!no-container' \
-e ECO_CNF_RAN_ACM_OPERATOR_NAMESPACE=open-cluster-management \
-e ECO_TEST_TRACE=true \
-e ECO_VERBOSE_SCRIPT=true \
"

ECO_GOTESTS_FEATURES=(gitopsztp deploymenttypes)

cd /eco-ci-cd

for feature in "${ECO_GOTESTS_FEATURES[@]}"; do
  TESTS_SCRIPT_PATH="/tmp/eco_gotests_${feature}"

  echo "Preparing eco-gotests for feature: ${feature}"
  ansible-playbook -vv ./playbooks/deploy-run-eco-gotests.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    -e "eco_gotest_dir=${TESTS_SCRIPT_PATH}" \
    -e "kubeconfig=${SPOKE_KUBECONFIG}" \
    -e "features=${feature}" \
    -e "labels=" \
    -e "eco_gotests_tag=latest" \
    -e "eco_worker_label=worker" \
    -e "hub_clusterconfigs_path=${HUB_CLUSTERCONFIGS_PATH}" \
    -e "mirror_registry=${MIRROR_REGISTRY}" \
    -e "additional_test_env_variables='${ADDITIONAL_TEST_ENV_VARS}'"
done

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
# Read SSH key directly from vault mount (raw file, no YAML parsing needed)
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"

chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

for feature in "${ECO_GOTESTS_FEATURES[@]}"; do
  remote_dir="/tmp/eco_gotests_${feature}"
  echo "Run eco-gotests ${feature} tests via ssh tunnel"
  ssh -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" \
    -i "${PROJECT_DIR}/temp_ssh_key" "cd ${remote_dir}; ./eco-gotests-run.sh || true"
done

echo "Gather artifacts from bastion"
# shellcheck disable=SC2154
for feature in "${ECO_GOTESTS_FEATURES[@]}"; do
  remote_dir="/tmp/eco_gotests_${feature}"
  artifact_dir="${ARTIFACT_DIR}/junit_eco_gotests_${feature}"
  mkdir -p "${artifact_dir}"
  scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:${remote_dir}/report/*.xml" "${artifact_dir}/"
done

rm -rf "${PROJECT_DIR}/temp_ssh_key"

echo "Store Polarion report for reporter step"
for feature in "${ECO_GOTESTS_FEATURES[@]}"; do
  artifact_dir="${ARTIFACT_DIR}/junit_eco_gotests_${feature}"
  if [ -f "${artifact_dir}/report_testrun.xml" ]; then
    mv "${artifact_dir}/report_testrun.xml" "${SHARED_DIR}/polarion_testrun_${feature}.xml"
    cp "${SHARED_DIR}/polarion_testrun_${feature}.xml" "${SHARED_DIR}/junit_${feature}_suite_test_junit.xml"
  fi
done
