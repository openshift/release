#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
COMMON_VARIABLES="/var/common_variables"

install_vars() {
  local src="$1"
  local allow_host_vars="$2"
  local base dest_dir name

  base="$(basename "$src")"

  case "$base" in
    ansible_group_*)
      dest_dir="${ECO_CI_CD_INVENTORY_PATH}/group_vars"
      name="${base#ansible_group_}"
      ;;
    *)
      if [ "${allow_host_vars}" != "true" ]; then
        echo "  skipped a file that is not a group var"
        return 0
      fi
      dest_dir="${ECO_CI_CD_INVENTORY_PATH}/host_vars"
      case "$base" in
        bastion*) name="bastion" ;;
        *)        name="${base}" ;;
      esac
      ;;
  esac
  cp "$src" "${dest_dir}/${name}"
}

process_mount() {
  local directory="$1"
  local allow_host_vars="$2"

  if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a valid directory"
    return 1
  fi

  # -L so that files exposed as symlinks by the secrets mount are matched as regular files
  while IFS= read -r filename; do
    install_vars "$filename" "${allow_host_vars}"
  done < <(find -L "$directory" -maxdepth 1 -type f ! -name '..*' | sort)
}

# SPOKE_CLUSTER may arrive as a JSON array (e.g. "['kni-qe-107']" or '["kni-qe-107"]') from test-level env
SPOKE_CLUSTER=$(echo "${SPOKE_CLUSTER}" | tr -d "[]'\" ")
if [[ "${SPOKE_CLUSTER}" == *,* ]]; then
  echo "Error: SPOKE_CLUSTER must resolve to exactly one cluster name, got: '${SPOKE_CLUSTER}'"
  exit 1
fi
if [[ -z "${SPOKE_CLUSTER}" ]]; then
  echo "Error: SPOKE_CLUSTER is empty after normalization"
  exit 1
fi
if [[ ! "${SPOKE_CLUSTER}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "Error: SPOKE_CLUSTER contains invalid characters: '${SPOKE_CLUSTER}' (only lowercase alphanumerics and hyphens allowed)"
  exit 1
fi

# HUB_CLUSTER may arrive as a JSON array (same as SPOKE_CLUSTER)
HUB_CLUSTER=$(echo "${HUB_CLUSTER}" | tr -d "[]'\" ")
if [[ "${HUB_CLUSTER}" == *,* ]]; then
  echo "Error: HUB_CLUSTER must resolve to exactly one cluster name, got: '${HUB_CLUSTER}'"
  exit 1
fi
if [[ -z "${HUB_CLUSTER}" ]]; then
  echo "Error: HUB_CLUSTER is empty after normalization"
  exit 1
fi
if [[ ! "${HUB_CLUSTER}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "Error: HUB_CLUSTER contains invalid characters: '${HUB_CLUSTER}' (only lowercase alphanumerics and hyphens allowed)"
  exit 1
fi

echo "SPOKE_CLUSTER=${SPOKE_CLUSTER}"
echo "HUB_CLUSTER=${HUB_CLUSTER}"
echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"

echo "Create inventory directories"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars" "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Processing hub cluster vars (${HUB_CLUSTER})"
process_mount "/var/clusters/${HUB_CLUSTER}" true

WORKDIR=$(mktemp -d)
HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/${HUB_CLUSTER}"
HUB_KUBECONFIG_PATH="${HUB_CLUSTERCONFIGS_PATH}/auth/kubeconfig"

ALL_VARS="${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"

echo "Set bastion ssh configuration"
# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "${WORKDIR}/temp_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${ALL_VARS}" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${WORKDIR}/temp_ssh_key"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=^ansible_user: ).*' "${ALL_VARS}" | sed "s/'//g")

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH_OPTS_KEEPALIVE=(-o ServerAliveInterval=60 -o ServerAliveCountMax=3 "${SSH_OPTS[@]}")

echo "Create remote working directory"
REMOTE_WORKDIR=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" "mktemp -d")

SPOKE_KUBECONFIG="${REMOTE_WORKDIR}/${SPOKE_CLUSTER}-kubeconfig"

cleanup() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
    "rm -rf '${REMOTE_WORKDIR}'" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "Extract spoke kubeconfig from hub via bastion"
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "set -o pipefail; oc --kubeconfig='${HUB_KUBECONFIG_PATH}' \
    get secret ${SPOKE_CLUSTER}-admin-kubeconfig \
    -n ${SPOKE_CLUSTER} \
    -o jsonpath='{.data.kubeconfig}' | base64 -d > '${SPOKE_KUBECONFIG}'"

echo "Wait for spoke worker node to be Ready"
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "oc --kubeconfig='${SPOKE_KUBECONFIG}' \
    wait --for=condition=Ready node \
    --selector=node-role.kubernetes.io/worker,\!node-role.kubernetes.io/master \
    --timeout=30m"

ACM_OPERATOR_NAMESPACE="open-cluster-management"

ADDITIONAL_TEST_ENV_VARS="\
-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true \
-e ECO_TEST_LABELS='!no-container' \
-e ECO_CNF_RAN_ACM_OPERATOR_NAMESPACE=${ACM_OPERATOR_NAMESPACE} \
-e ECO_TEST_TRACE=true \
-e ECO_VERBOSE_SCRIPT=true \
"

cd /eco-ci-cd

step_failed=0

for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="${REMOTE_WORKDIR}/eco_gotests_${feature}"
  echo "Generate eco-gotests scripts for feature: ${feature}"

  playbook_rc=0
  ansible-playbook ./playbooks/deploy-run-eco-gotests.yaml \
    -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "kubeconfig=${SPOKE_KUBECONFIG} features=${feature} labels='' eco_gotest_dir=${ECO_GOTEST_DIR}" \
    --extra-vars "eco_gotests_tag=latest eco_worker_label=worker" \
    --extra-vars "hub_clusterconfigs_path=${HUB_CLUSTERCONFIGS_PATH}" \
    --extra-vars "mirror_registry=${MIRROR_REGISTRY}" \
    --extra-vars "additional_test_env_variables='${ADDITIONAL_TEST_ENV_VARS}'" \
    -vv || playbook_rc=$?
  if [[ ${playbook_rc} -ne 0 ]]; then
    echo "ERROR: ansible-playbook failed for feature ${feature} (exit code ${playbook_rc})"
    step_failed=1
  fi
done

echo "Run eco-gotests via SSH"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="${REMOTE_WORKDIR}/eco_gotests_${feature}"
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
  ECO_GOTEST_DIR="${REMOTE_WORKDIR}/eco_gotests_${feature}"
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
