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

echo "CLUSTER_NAME=${CLUSTER_NAME}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "ECO_GOTESTS_LABELS=${ECO_GOTESTS_LABELS}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"

echo "Create group_vars directory"
mkdir -p "${INVENTORY_PATH}/group_vars"

echo "Process common group variables (all, bastions)"
process_inventory /var/group_variables/common/all      "${INVENTORY_PATH}/group_vars/all"
process_inventory /var/group_variables/common/bastions "${INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir -p "${INVENTORY_PATH}/host_vars"

echo "Process hub bastion host variables"
process_inventory "/var/host_variables/${CLUSTER_NAME}/bastion" "${INVENTORY_PATH}/host_vars/bastion"

WORKDIR=$(mktemp -d)
HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}"
HUB_KUBECONFIG_PATH="${HUB_CLUSTERCONFIGS_PATH}/auth/kubeconfig"

echo "Set bastion ssh configuration"
install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${WORKDIR}/temp_ssh_key"
trap 'rm -rf "${WORKDIR}"' EXIT

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH_OPTS_KEEPALIVE=(-o ServerAliveInterval=60 -o ServerAliveCountMax=3 "${SSH_OPTS[@]}")

ACM_OPERATOR_NAMESPACE="open-cluster-management"

ADDITIONAL_TEST_ENV_VARS="\
-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true \
-e ECO_CNF_RAN_ACM_OPERATOR_NAMESPACE=${ACM_OPERATOR_NAMESPACE} \
-e ECO_TEST_TRACE=true \
-e ECO_VERBOSE_SCRIPT=true \
"

cd "${ECO_CI_CD_DIR}"

step_failed=0

echo "Generate eco-gotests scripts for O-RAN features"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="/tmp/eco_gotests_${feature}"
  echo "Generate eco-gotests scripts for feature: ${feature}"

  playbook_rc=0
  ansible-playbook ./playbooks/deploy-run-eco-gotests.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${HUB_KUBECONFIG_PATH} features=${feature} labels='${ECO_GOTESTS_LABELS}' eco_gotest_dir=${ECO_GOTEST_DIR}" \
    --extra-vars "eco_gotests_tag=latest" \
    --extra-vars "hub_clusterconfigs_path=${HUB_CLUSTERCONFIGS_PATH}" \
    --extra-vars "mirror_registry=${MIRROR_REGISTRY}" \
    --extra-vars "additional_test_env_variables='${ADDITIONAL_TEST_ENV_VARS}'" \
    -vv || playbook_rc=$?
  if [[ ${playbook_rc} -ne 0 ]]; then
    echo "ERROR: ansible-playbook failed for feature ${feature} (exit code ${playbook_rc})"
    step_failed=1
  fi
done

echo "Run eco-gotests O-RAN features via SSH (in order)"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="/tmp/eco_gotests_${feature}"
  echo "Run eco-gotests ${feature} tests via SSH"
  feature_rc=0
  ssh "${SSH_OPTS_KEEPALIVE[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
    "cd ${ECO_GOTEST_DIR} && ./eco-gotests-run.sh" || feature_rc=$?
  if [[ ${feature_rc} -ne 0 ]]; then
    echo "ERROR: eco-gotests ${feature} exited with code ${feature_rc}"
    step_failed=1
  fi
done

echo "Collect artifacts from bastion"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="/tmp/eco_gotests_${feature}"
  ARTIFACT_SUBDIR="${ARTIFACT_DIR}/junit_eco_gotests_${feature}"
  mkdir -p "${ARTIFACT_SUBDIR}"

  scp_stderr=$(mktemp)
  scp_rc=0
  scp -r "${SSH_OPTS[@]}" -i "${WORKDIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:${ECO_GOTEST_DIR}/report/*.xml" \
    "${ARTIFACT_SUBDIR}/" 2>"${scp_stderr}" || scp_rc=$?
  if [[ ${scp_rc} -ne 0 ]]; then
    scp_err_msg=$(cat "${scp_stderr}")
    if [[ "${scp_err_msg}" == *"No such file"* || "${scp_err_msg}" == *"not found"* ]]; then
      echo "No report files found for feature ${feature} (non-fatal): ${scp_err_msg}"
    else
      echo "WARNING: scp failed for feature ${feature} (exit code ${scp_rc}): ${scp_err_msg}"
    fi
  fi
  rm -f "${scp_stderr}"
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
    "cd ${ECO_GOTEST_DIR}/report && find . -mindepth 1 ! -name '*.xml' -type f \
     | zip /tmp/k8sreporter_${feature}.zip -@ 2>/dev/null || true"
  scp "${SSH_OPTS[@]}" -i "${WORKDIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/k8sreporter_${feature}.zip" \
    "${ARTIFACT_SUBDIR}/" 2>/dev/null || echo "No k8sreporter artifacts for ${feature} — skipping"
done

echo "Copy reports to SHARED_DIR with prefixes"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ARTIFACT_SUBDIR="${ARTIFACT_DIR}/junit_eco_gotests_${feature}"

  # Polarion reports
  for f in "${ARTIFACT_SUBDIR}"/report_*.xml; do
    if [[ -f "$f" ]]; then
      filename=$(basename "$f")
      echo "Copying polarion report: ${feature}/${filename} -> polarion_${feature}_${filename}"
      cp "$f" "${SHARED_DIR}/polarion_${feature}_${filename}"
    fi
  done

  # Junit reports
  for f in "${ARTIFACT_SUBDIR}"/*.xml; do
    if [[ -f "$f" ]]; then
      filename=$(basename "$f")
      if [[ "$filename" == *junit*.xml || "$filename" == *_suite_*.xml ]] && [[ "$filename" != report_*.xml ]]; then
        echo "Copying junit report: ${feature}/${filename} -> junit_${feature}_${filename}"
        cp "$f" "${SHARED_DIR}/junit_${feature}_${filename}"
      fi
    fi
  done
done

exit "${step_failed}"
