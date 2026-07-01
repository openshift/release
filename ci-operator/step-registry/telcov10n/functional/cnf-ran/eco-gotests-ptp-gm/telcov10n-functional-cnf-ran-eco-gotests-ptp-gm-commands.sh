#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

ECO_CI_CD_DIR=/eco-ci-cd
INVENTORY_PATH="${ECO_CI_CD_DIR}/inventories/ocp-deployment"

process_inventory() {
  local directory="$1"
  local dest_file="$2"

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
    if [[ "$content" == *$'\n'* ]]; then
      echo "${varname}: |"
      echo "$content" | sed 's/^/  /'
    else
      echo "${varname}: '${content//\'/\'\'}'"
    fi
  done > "${dest_file}"
}

echo "Create group_vars directory"
mkdir -p "${INVENTORY_PATH}/group_vars"

echo "Process group inventory files"
process_inventory /var/group_variables/common/all      "${INVENTORY_PATH}/group_vars/all"
process_inventory /var/group_variables/common/bastions "${INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir -p "${INVENTORY_PATH}/host_vars"

echo "Process host inventory files"
process_inventory "/var/host_variables/${CLUSTER_NAME}/bastion" "${INVENTORY_PATH}/host_vars/bastion"

echo "Copy processed inventory files to SHARED_DIR for later steps"
cp "${INVENTORY_PATH}/group_vars/all"     "${SHARED_DIR}/all"
cp "${INVENTORY_PATH}/group_vars/bastions" "${SHARED_DIR}/bastions"
cp "${INVENTORY_PATH}/host_vars/bastion"  "${SHARED_DIR}/bastion"

HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}"
KUBECONFIG_PATH="${HUB_CLUSTERCONFIGS_PATH}/auth/kubeconfig"

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"
trap 'rm -f "${PROJECT_DIR}/temp_ssh_key"' EXIT

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

cd "${ECO_CI_CD_DIR}"

MIRROR_REGISTRY_VAR=""
if [[ -n "${MIRROR_REGISTRY}" ]]; then
  MIRROR_REGISTRY_VAR="mirror_registry=${MIRROR_REGISTRY}"
fi

printf 'ptp_cycle_configs: %s\n' "${PTP_CYCLE_CONFIGS:-[]}" > /tmp/ptp_cycle_configs.yml

ansible-playbook -vv ./playbooks/ran/deploy-run-eco-gotests-ptp-gm.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --tags setup \
  --extra-vars "hub_kubeconfig=${KUBECONFIG_PATH} \
    hub_clusterconfigs_path=${HUB_CLUSTERCONFIGS_PATH} \
    spoke_cluster_label_selector=${SPOKE_CLUSTER_LABEL_SELECTOR} \
    bmc_user=${BMC_USER} bmc_password=${BMC_PASSWORD} \
    labels='${ECO_GOTESTS_LABELS}' \
    cnf_test_image=${ECO_CNF_RAN_TEST_IMAGE} \
    ${MIRROR_REGISTRY_VAR}" \
  --extra-vars "@/tmp/ptp_cycle_configs.yml"

REMOTE_DIR="/tmp/eco_gotests_ptp_gm"

echo "Run eco-gotests PTP GM tests via SSH"
ssh -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null "${BASTION_USER}@${BASTION_IP}" \
  -i "${PROJECT_DIR}/temp_ssh_key" "cd ${REMOTE_DIR}; ./eco-gotests-ptp-gm-run.sh || true"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

echo "Gather artifacts from bastion"

for feature in containernshide powermanagement deploymenttypes; do
  local_dir="${ARTIFACT_DIR}/junit_eco_gotests_${feature}_0"
  mkdir -p "${local_dir}"
  scp -r "${SSH_OPTS[@]}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests_${feature}_0/report/*.xml" \
    "${local_dir}/" || echo "No XML artifacts in eco_gotests_${feature}_0 — skipping"
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "cd /tmp/eco_gotests_${feature}_0/report && find . -mindepth 1 ! -name '*.xml' -type f \
     | zip /tmp/k8sreporter_${feature}_0.zip -@ 2>/dev/null || true"
  scp "${SSH_OPTS[@]}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/k8sreporter_${feature}_0.zip" \
    "${local_dir}/" 2>/dev/null || echo "No k8sreporter artifacts in eco_gotests_${feature}_0 — skipping"
done

PTP_CYCLE_COUNT=$(python3 -c "import json; print(len(json.loads('${PTP_CYCLE_CONFIGS:-[]}')))" 2>/dev/null || echo 0)
for i in $(seq 0 "${PTP_CYCLE_COUNT}"); do
  local_dir="${ARTIFACT_DIR}/junit_eco_gotests_ptp_gm_${i}"
  mkdir -p "${local_dir}"
  scp -r "${SSH_OPTS[@]}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests_ptp_gm_${i}/report/*.xml" \
    "${local_dir}/" || echo "No XML artifacts in eco_gotests_ptp_gm_${i} — skipping"
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "cd /tmp/eco_gotests_ptp_gm_${i}/report && find . -mindepth 1 ! -name '*.xml' -type f \
     | zip /tmp/k8sreporter_ptp_gm_${i}.zip -@ 2>/dev/null || true"
  scp "${SSH_OPTS[@]}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/k8sreporter_ptp_gm_${i}.zip" \
    "${local_dir}/" 2>/dev/null || echo "No k8sreporter artifacts in eco_gotests_ptp_gm_${i} — skipping"
done

echo "Process report files on bastion"
BASTION_REPORT_DIR="/tmp/test_reports"
ansible-playbook ./playbooks/ran/deploy-run-eco-gotests-ptp-gm.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --tags process \
  --extra-vars "eco_gotest_base_dir=/tmp/eco_gotests_ptp_gm \
    ptp_report_dir=${BASTION_REPORT_DIR}" \
  --extra-vars "@/tmp/ptp_cycle_configs.yml"

