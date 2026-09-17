#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

ECO_CI_CD_DIR=/eco-ci-cd
ECO_CI_CD_INVENTORY_PATH="${ECO_CI_CD_DIR}/inventories/cnf"
COMMON_VARIABLES="/var/common_variables"
HYPERVISOR_VARIABLES="/var/hypervisors"

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
  echo "Error: SPOKE_CLUSTER contains invalid characters: '${SPOKE_CLUSTER}'"
  exit 1
fi

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
  echo "Error: HUB_CLUSTER contains invalid characters: '${HUB_CLUSTER}'"
  exit 1
fi

echo "SPOKE_CLUSTER=${SPOKE_CLUSTER}"
echo "HUB_CLUSTER=${HUB_CLUSTER}"
if [[ -z "${CNF_GOTESTS_FEATURES}" ]]; then
  echo "Error: CNF_GOTESTS_FEATURES must be set and non-empty"
  exit 1
fi
echo "CNF_GOTESTS_FEATURES=${CNF_GOTESTS_FEATURES}"
echo "DOWNSTREAM_TEST_REPO=${DOWNSTREAM_TEST_REPO}"

echo "Create inventory directories"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars" "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Processing hub cluster vars (${HUB_CLUSTER})"
process_mount "/var/clusters/${HUB_CLUSTER}" true

echo "Processing hypervisor vars"
cp "${HYPERVISOR_VARIABLES}/hypervisor" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/hypervisor"

WORKDIR=$(mktemp -d)
HUB_CLUSTERCONFIGS_PATH="/home/telcov10n/project/generated/${HUB_CLUSTER}"
HUB_KUBECONFIG_PATH="${HUB_CLUSTERCONFIGS_PATH}/auth/kubeconfig"

ALL_VARS="${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"

echo "Set bastion SSH configuration"
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
DOWNSTREAM_TEST_DIR="${REMOTE_WORKDIR}/cnf-gotests"
DOWNSTREAM_REPORT_PATH="${REMOTE_WORKDIR}/downstream_report"

cleanup() {
  ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
    "rm -rf '${REMOTE_WORKDIR}'" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "Extract spoke kubeconfig from hub via bastion"
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "oc --kubeconfig='${HUB_KUBECONFIG_PATH}' \
    get secret ${SPOKE_CLUSTER}-admin-kubeconfig \
    -n ${SPOKE_CLUSTER} \
    -o jsonpath='{.data.kubeconfig}' | base64 -d > '${SPOKE_KUBECONFIG}'"

echo "Discover spoke BMC IP from hub BareMetalHost"
BMC_HOSTS=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "oc --kubeconfig='${HUB_KUBECONFIG_PATH}' \
    get baremetalhost -n ${SPOKE_CLUSTER} \
    -o jsonpath='{.items[0].spec.bmc.address}' \
  | grep -oP '(?<=\[)[0-9a-fA-F:]+(?=\])|\d{1,3}(?:\.\d{1,3}){3}' | head -1" 2>/dev/null || true)
echo "BMC_HOSTS=${BMC_HOSTS}"

echo "Read BMC credentials from ansible group_all secret"
bmc_user_from_secret=$(grep -oP "(?<=^bmc_user: ).*" "${ALL_VARS}" | sed "s/'//g") || true
bmc_password_from_secret=$(grep -oP "(?<=^bmc_password: ).*" "${ALL_VARS}" | sed "s/'//g") || true
[[ -n "${bmc_user_from_secret}" ]] && BMC_USER="${bmc_user_from_secret}"
[[ -n "${bmc_password_from_secret}" ]] && BMC_PASSWORD="${bmc_password_from_secret}"
echo "BMC_USER=${BMC_USER}"

echo "Resolve OCP tools image for CNF_TEST_IMAGE (available on disconnected registry)"
CNF_TEST_IMAGE=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "oc --kubeconfig='${SPOKE_KUBECONFIG}' adm release info --image-for=tools")
echo "CNF_TEST_IMAGE=${CNF_TEST_IMAGE}"

cd "${ECO_CI_CD_DIR}"

echo "Run ansible playbook to generate downstream test script"
ansible-playbook ./playbooks/cnf/deploy-run-downstream-tests-script.yaml \
  -i ./inventories/cnf/run-tests.yaml \
  --extra-vars "kubeconfig=${SPOKE_KUBECONFIG} \
    downstream_test_repo=${DOWNSTREAM_TEST_REPO} \
    downstream_test_dir=${REMOTE_WORKDIR}/ \
    downstream_test_report_path=${DOWNSTREAM_REPORT_PATH} \
    metallb_vlans= \
    switch_interfaces= \
    switch_user= \
    switch_pass= \
    switch_address= \
    switch_lag_names= \
    cnf_interfaces= \
    tests_mlb_addr_list=" \
  -vv

printf 'cnf_gotests_features: "%s"\n' "${CNF_GOTESTS_FEATURES}" > /tmp/cnf_gotests_features.yml

echo "Run ansible playbook to set up cnf-gotests PTP GM"
ansible-playbook ./playbooks/ran/deploy-run-cnf-gotests-ptp-gm.yaml \
  -i ./inventories/cnf/run-tests.yaml \
  --extra-vars "kubeconfig=${SPOKE_KUBECONFIG} \
    downstream_test_dir=${DOWNSTREAM_TEST_DIR} \
    downstream_test_report_path=${DOWNSTREAM_REPORT_PATH} \
    cnf_test_image=${CNF_TEST_IMAGE} \
    mirror_registry=${MIRROR_REGISTRY} \
    bmc_hosts=${BMC_HOSTS} \
    bmc_user=${BMC_USER} \
    bmc_password=${BMC_PASSWORD}" \
  --extra-vars "@/tmp/cnf_gotests_features.yml" \
  -vv

echo "Run cnf-gotests PTP GM tests via SSH"
cnf_gotests_rc=0
ssh "${SSH_OPTS_KEEPALIVE[@]}" "${BASTION_USER}@${BASTION_IP}" \
  -i "${WORKDIR}/temp_ssh_key" \
  "cd ${DOWNSTREAM_TEST_DIR}; ./cnf-gotests-ptp-gm-run.sh || true"

echo "Process report files on bastion"
BASTION_REPORT_DIR="/tmp/test_reports"
ansible-playbook ./playbooks/ran/deploy-run-cnf-gotests-ptp-gm.yaml \
  -i ./inventories/cnf/run-tests.yaml \
  --tags process \
  --extra-vars "downstream_test_report_path=${DOWNSTREAM_REPORT_PATH} \
    ptp_report_dir=${BASTION_REPORT_DIR}" \
  -vv

echo "Create artifact directory for reports"
mkdir -p "${ARTIFACT_DIR}/junit_downstream/"

echo "Gather reports from bastion"
scp_stderr=$(mktemp)
scp_rc=0
scp -r "${SSH_OPTS[@]}" -i "${WORKDIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:${DOWNSTREAM_REPORT_PATH}/*.xml" \
  "${ARTIFACT_DIR}/junit_downstream/" 2>"${scp_stderr}" || scp_rc=$?
if [[ ${scp_rc} -ne 0 ]]; then
  scp_err_msg=$(cat "${scp_stderr}")
  if [[ "${scp_err_msg}" == *"No such file"* || "${scp_err_msg}" == *"not found"* ]]; then
    echo "No report files found on bastion (non-fatal): ${scp_err_msg}"
  else
    echo "ERROR: scp failed (exit code ${scp_rc}) copying reports from ${BASTION_USER}@${BASTION_IP}:${DOWNSTREAM_REPORT_PATH}/*.xml"
    echo "stderr: ${scp_err_msg}"
    rm -f "${scp_stderr}"
    exit 1
  fi
fi
rm -f "${scp_stderr}"

exit "${cnf_gotests_rc}"
