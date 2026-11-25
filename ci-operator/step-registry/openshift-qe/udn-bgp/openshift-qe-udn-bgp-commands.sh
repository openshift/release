#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ ! -f "${SHARED_DIR}/frr-peer-address" ]]; then
  echo "ERROR: ${SHARED_DIR}/frr-peer-address not found; run openshift-qe-bgp-setup-udn-bgp first" >&2
  exit 1
fi
FRR_PEER_IP=$(tr -d '[:space:]' < "${SHARED_DIR}/frr-peer-address")
if [[ -z "${FRR_PEER_IP}" ]]; then
  echo "ERROR: ${SHARED_DIR}/frr-peer-address is empty" >&2
  exit 1
fi
echo "FRR peer address: ${FRR_PEER_IP}"

UUID=$(uuidgen)

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags "${REPO_URL}.git" | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
if [ "${E2E_VERSION}" == "default" ]; then
  E2E_BRANCH="${LATEST_TAG}"
else
  E2E_BRANCH="${E2E_VERSION}"
fi

$WAS_TRACING && set -x

# Configure SSH to the external FRR bastion (AWS direct, BM via jumphost proxy).
if [[ -f "${SHARED_DIR}/bastion_ssh_key" ]]; then
  BASTION_SSH_KEY="/tmp/bastion_ssh_key"
  cp "${SHARED_DIR}/bastion_ssh_key" "${BASTION_SSH_KEY}"
  chmod 400 "${BASTION_SSH_KEY}"
  BASTION_HOST=$(cat "${SHARED_DIR}/bastion_public_address")
  BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user" 2>/dev/null || echo "root")
  SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null"
  BASTION_WORK_DIR="/root/udn-bgp"
  BASTION_KUBECONFIG_PATH=""
elif [[ -f "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key" ]]; then
  BASTION_SSH_KEY="${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
  JUMPHOST=$(cat "${CLUSTER_PROFILE_DIR}/address")
  BASTION_HOST=$(cat "${CLUSTER_PROFILE_DIR}/bastion" 2>/dev/null || cat "${SHARED_DIR}/bastion")
  BASTION_SSH_USER="root"
  SSH_ARGS="-i ${BASTION_SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  BASTION_WORK_DIR="/tmp"
  TYPE=${TYPE:-mno}
  if [[ "${TYPE}" == "hmno" ]]; then
    BASTION_KUBECONFIG_PATH="/root/mno/kubeconfig"
  else
    BASTION_KUBECONFIG_PATH="/root/${TYPE}/kubeconfig"
  fi
else
  echo "ERROR: No bastion SSH credentials found" >&2
  exit 1
fi

bastion_ssh() {
  if [[ -n "${JUMPHOST:-}" ]]; then
    ssh ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${BASTION_SSH_USER}@${JUMPHOST}" "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
  else
    ssh ${SSH_ARGS} "${BASTION_SSH_USER}@${BASTION_HOST}" "$@"
  fi
}

bastion_scp() {
  if [[ -n "${JUMPHOST:-}" ]]; then
    scp ${SSH_ARGS} -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${BASTION_SSH_USER}@${JUMPHOST}" "$@"
  else
    scp ${SSH_ARGS} "$@"
  fi
}

echo "=== Run UDN-BGP kube-burner from bastion ==="

# ssh concatenates remote argv without quoting, so values with spaces
# (EXTRA_FLAGS) never arrive intact. Pass space-free vars and rebuild flags
# on the bastion. PROW vars are required for utils/index.sh metadata indexing.
BASTION_ENV=( \
  BASTION_KUBECONFIG_PATH="${BASTION_KUBECONFIG_PATH}" \
  BASTION_WORK_DIR="${BASTION_WORK_DIR}" \
  BUILD_ID="${BUILD_ID:-}" \
  E2E_BRANCH="${E2E_BRANCH}" \
  ENABLE_LOCAL_INDEX="${ENABLE_LOCAL_INDEX}" \
  ES_METADATA_INDEX="${ES_METADATA_INDEX:-perf_scale_ci}" \
  ES_SERVER="${ES_SERVER}" \
  FRR_PEER_IP="${FRR_PEER_IP}" \
  GC="${GC}" \
  ITERATIONS="${ITERATIONS}" \
  JOB_NAME="${JOB_NAME:-}" \
  JOB_TYPE="${JOB_TYPE:-}" \
  KUBE_BURNER_VERSION="${KUBE_BURNER_VERSION}" \
  PROFILE_TYPE="${PROFILE_TYPE}" \
  PROW_JOB_ID="${PROW_JOB_ID:-}" \
  PULL_NUMBER="${PULL_NUMBER:-0}" \
  REPO_NAME="${REPO_NAME:-}" \
  REPO_OWNER="${REPO_OWNER:-}" \
  REPO_URL="${REPO_URL}" \
  UUID="${UUID}" \
)

set +o errexit
set +x
bastion_ssh env "${BASTION_ENV[@]}" bash -s <<'EOF'
set -o errexit
set -o pipefail

if [[ -n "${BASTION_KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${BASTION_KUBECONFIG_PATH}"
fi

mkdir -p "${BASTION_WORK_DIR}"
cd "${BASTION_WORK_DIR}"
rm -rf e2e-benchmarking
git clone "${REPO_URL}" --branch "${E2E_BRANCH}" --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

for node in $(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}'); do
  echo "Pre-loading image on node ${node}..."
  oc debug "node/${node}" -n default -- chroot /host crictl pull quay.io/cloud-bulldozer/sampleapp:latest
done

EXTRA_FLAGS=""
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
  EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+=" --gc-metrics=false --profile-type=${PROFILE_TYPE}"
EXTRA_FLAGS+=" --frr-external-ip=${FRR_PEER_IP}"

export WORKLOAD=udn-bgp
export ES_SERVER ES_METADATA_INDEX EXTRA_FLAGS GC ITERATIONS KUBE_BURNER_VERSION UUID
export PROW_JOB_ID BUILD_ID JOB_NAME JOB_TYPE PULL_NUMBER REPO_OWNER REPO_NAME
set +o errexit
./run.sh
exit $?
EOF
RUN_EXIT_CODE=$?
$WAS_TRACING && set -x
set -o errexit

METRICS_FOLDER="${BASTION_WORK_DIR}/e2e-benchmarking/workloads/kube-burner-ocp-wrapper/collected-metrics-${UUID}"
if bastion_ssh "test -f ${METRICS_FOLDER}/jobSummary.json"; then
  bastion_scp -r "${BASTION_SSH_USER}@${BASTION_HOST}:${METRICS_FOLDER}" "${ARTIFACT_DIR}/"
fi

exit ${RUN_EXIT_CODE}
