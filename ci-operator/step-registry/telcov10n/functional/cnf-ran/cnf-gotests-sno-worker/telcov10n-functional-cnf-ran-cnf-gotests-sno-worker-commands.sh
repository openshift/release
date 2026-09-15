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

MOUNTED_SPOKE_INVENTORY="/var/clusters/${SPOKE_CLUSTER}/spoke-master0"
if [[ -f "${MOUNTED_SPOKE_INVENTORY}" ]]; then
  echo "Installing spoke cluster inventory from mount"
  cp "${MOUNTED_SPOKE_INVENTORY}" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/spoke-master0"
fi

echo "Processing hub cluster vars (${HUB_CLUSTER})"
process_mount "/var/clusters/${HUB_CLUSTER}" true

echo "Processing spoke cluster vars (${SPOKE_CLUSTER})"
process_mount "/var/clusters/${SPOKE_CLUSTER}" true

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

echo "Wait for spoke worker node to be Ready"
ssh "${SSH_OPTS_KEEPALIVE[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "oc --kubeconfig='${SPOKE_KUBECONFIG}' \
    wait --for=condition=Ready node \
    --selector=node-role.kubernetes.io/worker,\!node-role.kubernetes.io/master \
    --timeout=30m"

echo "Label spoke worker nodes with workercnf role"
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "oc --kubeconfig='${SPOKE_KUBECONFIG}' \
    label node --overwrite \
    --selector=node-role.kubernetes.io/worker,\!node-role.kubernetes.io/master \
    node-role.kubernetes.io/workercnf="

echo "Write pull secret to bastion for registry authentication"
PULL_SECRET_PATH="${REMOTE_WORKDIR}/pull-secret.json"
install -m 600 /dev/null "${WORKDIR}/pull-secret.json"
grep -oP '(?<=^pull_secret_string: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions" \
  | sed "s/'//g" | base64 -d > "${WORKDIR}/pull-secret.json"
scp "${SSH_OPTS[@]}" -i "${WORKDIR}/temp_ssh_key" \
  "${WORKDIR}/pull-secret.json" "${BASTION_USER}@${BASTION_IP}:${PULL_SECRET_PATH}"

echo "Resolve OCP tools image for CNF_TEST_IMAGE"
CNF_TEST_IMAGE=$(ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "REGISTRY_AUTH_FILE='${PULL_SECRET_PATH}' oc --kubeconfig='${SPOKE_KUBECONFIG}' adm release info --image-for=tools")
echo "CNF_TEST_IMAGE=${CNF_TEST_IMAGE}"

cd /eco-ci-cd

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
    tests_mlb_addr_list= \
    frr_image_link= \
    network_test_container_link=" \
  -vv

echo "Mirror workload images to disconnected registry"
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" bash -s -- \
  "${MIRROR_REGISTRY}" <<'MIRROR_SCRIPT'
set -e
set -o pipefail

MIRROR_REGISTRY="$1"
AUTHFILE="${HOME}/auth/auth.compact.json"
ACCEPT_POLICY='{"default":[{"type":"insecureAcceptAnything"}]}'

if [[ -z "${MIRROR_REGISTRY}" ]]; then
  echo "MIRROR_REGISTRY not set, skipping image mirror"
  exit 0
fi

for image in container-perf-tools/oslat:latest container-perf-tools/stress-ng:latest; do
  echo "Mirroring quay.io/${image} → ${MIRROR_REGISTRY}/${image}"
  skopeo copy \
    --policy <(echo "${ACCEPT_POLICY}") \
    --authfile "${AUTHFILE}" \
    --dest-tls-verify=false \
    "docker://quay.io/${image}" \
    "docker://${MIRROR_REGISTRY}/${image}"
done

echo "Image mirroring complete"
MIRROR_SCRIPT

echo "Fix ginkgo, patch generated script, install nc, and run tests via SSH"
cnf_gotests_rc=0
ssh "${SSH_OPTS_KEEPALIVE[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" bash -s -- \
  "${DOWNSTREAM_TEST_DIR}" "${CNF_GOTESTS_FEATURES}" "${CNF_TEST_IMAGE}" "${MIRROR_REGISTRY}" "${DOWNSTREAM_REPORT_PATH}" <<'REMOTE_SCRIPT' || cnf_gotests_rc=$?
set -e
set -o pipefail

DOWNSTREAM_TEST_DIR="$1"
CNF_GOTESTS_FEATURES="$2"
CNF_TEST_IMAGE="$3"
MIRROR_REGISTRY="$4"
DOWNSTREAM_REPORT_PATH="$5"
GENERATED_SCRIPT="${DOWNSTREAM_TEST_DIR}/downstream-tests-run.sh"

mkdir -p "${DOWNSTREAM_REPORT_PATH}"

if [[ ! -f "${GENERATED_SCRIPT}" ]]; then
  echo "ERROR: ${GENERATED_SCRIPT} not found"
  exit 1
fi

if ! command -v nc &>/dev/null; then
  echo "Installing nmap-ncat (provides nc for node reachability checks)..."
  sudo dnf install -y nmap-ncat
fi

echo "Re-install ginkgo CLI from project vendor to match library version..."
export PATH="/usr/local/go/bin:$PATH"
cd "${DOWNSTREAM_TEST_DIR}"
go install -mod=vendor github.com/onsi/ginkgo/v2/ginkgo
echo "Ginkgo version fix complete"

echo "Patching generated script with feature selection and disconnected image overrides..."
PATCH_EXPORTS="export FEATURES=${CNF_GOTESTS_FEATURES}"
PATCH_EXPORTS="${PATCH_EXPORTS}\nexport CNF_TEST_IMAGE=${CNF_TEST_IMAGE}"
if [[ -n "${MIRROR_REGISTRY}" ]]; then
  PATCH_EXPORTS="${PATCH_EXPORTS}\nexport OSLAT_TEST_IMAGE=${MIRROR_REGISTRY}/container-perf-tools/oslat:latest"
  PATCH_EXPORTS="${PATCH_EXPORTS}\nexport STRESSNG_TEST_IMAGE=${MIRROR_REGISTRY}/container-perf-tools/stress-ng:latest"
fi

sed -i "s|^make test-all|${PATCH_EXPORTS}\nmake test-features|" "${GENERATED_SCRIPT}"

echo "Running cnf-gotests..."
./downstream-tests-run.sh || exit $?
REMOTE_SCRIPT

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

echo "Copy reports to SHARED_DIR with prefixes"
for f in "${ARTIFACT_DIR}"/junit_downstream/*_polarion.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    echo "Copying polarion report: $filename -> polarion_${filename}"
    cp "$f" "${SHARED_DIR}/polarion_${filename}"
  fi
done

for f in "${ARTIFACT_DIR}"/junit_downstream/*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f")
    if [[ "$filename" == *_suite_test.xml ]] && [[ "$filename" != *_polarion.xml ]]; then
      echo "Copying junit report: $filename -> junit_${filename}"
      cp "$f" "${SHARED_DIR}/junit_${filename}"
    fi
  fi
done

exit "${cnf_gotests_rc}"
