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

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
SPOKE_KUBECONFIG_PATH="/tmp/${SPOKE_CLUSTER_NAME}-kubeconfig"

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"
trap 'rm -f "${PROJECT_DIR}/temp_ssh_key"' EXIT

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

echo "Extracting spoke kubeconfig from hub ACM"
ssh -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "KUBECONFIG=${KUBECONFIG_PATH} \
  oc get secret -n ${SPOKE_CLUSTER_NAME} ${SPOKE_CLUSTER_NAME}-admin-kubeconfig \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > ${SPOKE_KUBECONFIG_PATH}"

cd /eco-ci-cd

printf 'ptp_cycle_configs: %s\n' "${PTP_CONFIGS}" > /tmp/ptp_cycle_configs.yml

echo "Run eco-gotests PTP suite — deploy test script on bastion"
ansible-playbook -vv ./playbooks/ran/deploy-run-eco-gotests-ptp.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --tags setup \
  --extra-vars "kubeconfig=${SPOKE_KUBECONFIG_PATH} \
    spoke_kubeconfig=${SPOKE_KUBECONFIG_PATH} \
    hub_clusterconfigs_path=/home/telcov10n/project/generated/${CLUSTER_NAME} \
    features=ptp \
    labels='!no-container' \
    eco_gotest_base_dir=/tmp/eco_gotests_ptp \
    eco_gotests_tag=latest \
    test_timeout=3h \
    mirror_registry=${MIRROR_REGISTRY} \
    pull_container_image=true \
    additional_test_env_variables='-e ECO_TEST_TRACE=true -e ECO_VERBOSE_SCRIPT=true'" \
  --extra-vars "@/tmp/ptp_cycle_configs.yml"

echo "Run eco-gotests PTP — all cycles via generated script on bastion"
ssh -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=120 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" \
  -i "${PROJECT_DIR}/temp_ssh_key" \
  "cd /tmp/eco_gotests_ptp && ./eco-gotests-ptp-run.sh || true"

echo "Gather artifacts from bastion to ARTIFACT_DIR (for GCS)"
# SCP all XML files to ARTIFACT_DIR so Prow uploads them to GCS for debugging.
# This is the only transfer from bastion to CI pod — processing happens on the bastion.
for i in 0 1 2 3; do
  mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests_ptp_${i}"
  scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests_ptp_${i}/report/*.xml" \
    "${ARTIFACT_DIR}/junit_eco_gotests_ptp_${i}/" || true
done

echo "Process report files on bastion"
BASTION_REPORT_DIR="/tmp/ptp_reports"
ansible-playbook ./playbooks/ran/deploy-run-eco-gotests-ptp.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --tags process \
  --extra-vars "eco_gotest_base_dir=/tmp/eco_gotests_ptp \
    ptp_report_dir=${BASTION_REPORT_DIR}"
