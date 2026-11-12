#!/bin/bash
set -e
set -o pipefail


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

ECO_CI_CD_DIR=/eco-ci-cd
INVENTORY_PATH="${ECO_CI_CD_DIR}/inventories/ocp-deployment"

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

echo "Set bastion ssh configuration"
install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${WORKDIR}/temp_ssh_key"
trap 'rm -rf "${WORKDIR}"' EXIT

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SSH_OPTS_KEEPALIVE=(-o ServerAliveInterval=60 -o ServerAliveCountMax=3 "${SSH_OPTS[@]}")

ADDITIONAL_TEST_ENV_VARS="\
-e ECO_CNF_RAN_PROVISIONING_REQUEST_URL=${ORAN_PROVISIONING_REQUEST_URL} \
-e ECO_CNF_RAN_CLUSTER_TEMPLATE_AFFIX=${ORAN_CLUSTER_TEMPLATE_AFFIX} \
-e ECO_CNF_RAN_SPOKE1_NAME=${ORAN_SPOKE1_NAME} \
"

cd "${ECO_CI_CD_DIR}"

step_failed=0

echo "Deploy eco-gotests scripts for O-RAN features"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="/tmp/eco_gotests_${feature}"
  # ECO_GOTESTS_FEATURES entries are "oran-<label>" (e.g. oran-pre-provision).
  # eco-gotests expects a directory name ("oran") plus a Ginkgo label filter.
  oran_dir="${feature%%-*}"     # "oran-pre-provision" → "oran"
  oran_label="${feature#*-}"    # "oran-pre-provision" → "pre-provision"
  echo "Generate eco-gotests script for feature: ${feature} (dir=${oran_dir}, label=${oran_label})"

  playbook_rc=0
  ansible-playbook ./playbooks/ran/deploy-run-eco-gotests-oran.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "features=${oran_dir} labels=${oran_label} eco_gotest_dir=${ECO_GOTEST_DIR}" \
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

echo "Run eco-gotests O-RAN features via SSH (streaming output to CI pod)"
for feature in ${ECO_GOTESTS_FEATURES}; do
  ECO_GOTEST_DIR="/tmp/eco_gotests_${feature}"
  echo "Run eco-gotests ${feature} tests via SSH"
  # Use || true so test assertion failures do not set step_failed — the step
  # exits 0 and report/slack/verify-junit steps run normally. The overall job
  # failure is determined by telcov10n-verify-junit-reports-bastion.
  ssh "${SSH_OPTS_KEEPALIVE[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
    "cd ${ECO_GOTEST_DIR} && ./eco-gotests-oran-run.sh" || true
done

echo "Collect artifacts from bastion"
# Runs scripts/collect-eco-gotests-artifacts.py on the bastion (replaces the
# collect-eco-gotests-artifacts.yaml playbook invocation): renames testsuites
# to suite names, gathers JUnit XMLs to ${JUNIT_REPORT_DIR}, zips
# k8sreporter output and prepares /tmp/test_reports for the report step.
# Only the resulting artifacts are transferred to the CI pod via SCP.
echo "Copy artifact collection script to bastion"
scp "${SSH_OPTS[@]}" -i "${WORKDIR}/temp_ssh_key" \
  "${ECO_CI_CD_DIR}/scripts/collect-eco-gotests-artifacts.py" \
  "${BASTION_USER}@${BASTION_IP}:/tmp/collect-eco-gotests-artifacts.py"

echo "Determine OCP version for the k8sreporter directory"
# hub-deploy records the hub cluster version in SHARED_DIR earlier in the workflow.
OCP_VERSION="$(cat "${SHARED_DIR}/cluster_version" 2>/dev/null || echo unknown)"
K8S_REPORTER_DIR="/tmp/k8sreporter-${OCP_VERSION}"
# Where the collector stages junit_eco_gotests_<suite>/ dirs, fetched below.
BASTION_ARTIFACTS_DIR="/tmp/eco_gotests_artifacts"
echo "Using k8sreporter directory: ${K8S_REPORTER_DIR}"

echo "Run artifact collection on bastion"
collect_rc=0
ssh "${SSH_OPTS_KEEPALIVE[@]}" "${BASTION_USER}@${BASTION_IP}" -i "${WORKDIR}/temp_ssh_key" \
  "python3 /tmp/collect-eco-gotests-artifacts.py \
     --suites '${ECO_GOTESTS_FEATURES}' \
     --junit-dir '${JUNIT_REPORT_DIR}' \
     --k8s-reporter-dir '${K8S_REPORTER_DIR}' \
     --artifacts-dir '${BASTION_ARTIFACTS_DIR}'" || collect_rc=$?
if [[ ${collect_rc} -ne 0 ]]; then
  echo "ERROR: artifact collection failed on bastion (exit code ${collect_rc})"
  step_failed=1
fi

echo "Fetch collected artifacts to CI pod"
# The collector stages junit_eco_gotests_<suite>/ dirs on the bastion (every
# XML from the suite's report dir, the renamed JUnit copy and the k8sreporter
# zip), restoring the artifact layout of the former collect-artifacts playbook.
mkdir -p "${ARTIFACT_DIR}"
scp -r "${SSH_OPTS[@]}" -i "${WORKDIR}/temp_ssh_key" \
  "${BASTION_USER}@${BASTION_IP}:${BASTION_ARTIFACTS_DIR}/junit_eco_gotests_*" "${ARTIFACT_DIR}/" \
  || echo "No staged artifacts to fetch"

exit "${step_failed}"
