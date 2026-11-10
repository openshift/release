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

REPO_URL="${E2E_REPO:-https://github.com/cloud-bulldozer/e2e-benchmarking}"
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

# ---------------------------------------------------------------------------
# frr-k8s webhook live profiling and admission metrics
# ---------------------------------------------------------------------------
FRR_K8S_PERF_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/frr-k8s-webhook-perf"
FRR_K8S_WEBHOOK_NAME="frrconfigurationsvalidationwebhook.metallb.io"
FRR_K8S_PPROF_PID=""

# Fetch one pprof endpoint from the statuscleaner. The frr-k8s image is alpine,
# so busybox wget over oc exec keeps the listener on the pod's loopback.
capture_statuscleaner_profile() {
  local endpoint=$1
  local output=$2
  local pod
  pod=$(oc get pods -n openshift-frr-k8s -l component=frr-k8s-statuscleaner \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "${pod}" ]]; then
    echo "WARNING: no running frr-k8s-statuscleaner pod for ${endpoint}" >&2
    return 1
  fi
  timeout 300 oc exec -n openshift-frr-k8s "${pod}" -c frr-k8s-statuscleaner -- \
    wget -q -O - "http://127.0.0.1:6060/debug/pprof/${endpoint}" > "${output}"
}

start_frr_k8s_webhook_pprof() {
  if [[ "${FRR_K8S_WEBHOOK_PERF:-false}" != "true" ]]; then
    return
  fi
  mkdir -p "${FRR_K8S_PERF_DIR}/pprof"
  echo "=== Start frr-k8s statuscleaner pprof capture ==="
  (
    set +o errexit
    index=0
    while true; do
      index=$((index + 1))
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      capture_statuscleaner_profile "profile?seconds=60" \
        "${FRR_K8S_PERF_DIR}/pprof/${stamp}-cpu-${index}.pprof"
      capture_statuscleaner_profile "allocs" \
        "${FRR_K8S_PERF_DIR}/pprof/${stamp}-allocs-${index}.pprof"
      capture_statuscleaner_profile "goroutine?debug=1" \
        "${FRR_K8S_PERF_DIR}/pprof/${stamp}-goroutine-${index}.txt"
      sleep "${FRR_K8S_WEBHOOK_PPROF_INTERVAL:-300}"
    done
  ) > "${FRR_K8S_PERF_DIR}/pprof-capture.log" 2>&1 &
  FRR_K8S_PPROF_PID=$!
  trap stop_frr_k8s_webhook_pprof EXIT
  echo "pprof capture running in background (pid ${FRR_K8S_PPROF_PID})"
}

stop_frr_k8s_webhook_pprof() {
  if [[ -z "${FRR_K8S_PPROF_PID:-}" ]]; then
    return
  fi
  echo "=== Stop frr-k8s statuscleaner pprof capture ==="
  if command -v pkill >/dev/null 2>&1; then
    pkill -P "${FRR_K8S_PPROF_PID}" 2>/dev/null || true
  fi
  kill "${FRR_K8S_PPROF_PID}" 2>/dev/null || true
  wait "${FRR_K8S_PPROF_PID}" 2>/dev/null || true
  FRR_K8S_PPROF_PID=""

  # oc exec can truncate a stream, so drop profiles that are not valid gzip.
  if command -v gzip >/dev/null 2>&1; then
    local profile
    while IFS= read -r profile; do
      if ! gzip -t "${profile}" >/dev/null 2>&1; then
        echo "WARNING: discarding truncated profile ${profile}" >&2
        rm -f "${profile}"
      fi
    done < <(find "${FRR_K8S_PERF_DIR}/pprof" -type f -name '*.pprof')
  fi
}

# Snapshot kube-apiserver's own view of the webhook at one instant.
capture_frr_k8s_webhook_metrics() {
  if [[ "${FRR_K8S_WEBHOOK_PERF:-false}" != "true" ]]; then
    return
  fi
  local phase=$1
  local timestamp=$2
  local metrics_dir="${FRR_K8S_PERF_DIR}/metrics"
  local buckets="${metrics_dir}/${phase}-${timestamp}-buckets.json"
  mkdir -p "${metrics_dir}"

  if ! thanos_query \
      "apiserver_admission_webhook_admission_duration_seconds_bucket{name=\"${FRR_K8S_WEBHOOK_NAME}\"}" \
      "${timestamp}" > "${buckets}"; then
    echo "WARNING: kube-apiserver webhook admission metrics unavailable (${phase})" >&2
    return
  fi
  if [[ "$(jq -r '.data.result | length' "${buckets}" 2>/dev/null)" == "0" ]]; then
    echo "WARNING: no apiserver_admission_webhook_admission_duration_seconds series for ${FRR_K8S_WEBHOOK_NAME}" >&2
  fi

  thanos_query "apiserver_admission_webhook_request_total{name=\"${FRR_K8S_WEBHOOK_NAME}\"}" \
    "${timestamp}" > "${metrics_dir}/${phase}-${timestamp}-requests.json" || true
  thanos_query "apiserver_admission_webhook_rejection_count{name=\"${FRR_K8S_WEBHOOK_NAME}\"}" \
    "${timestamp}" > "${metrics_dir}/${phase}-${timestamp}-rejections.json" || true
  thanos_query "apiserver_admission_webhook_fail_open_count{name=\"${FRR_K8S_WEBHOOK_NAME}\"}" \
    "${timestamp}" > "${metrics_dir}/${phase}-${timestamp}-fail-open.json" || true
  echo "Captured frr-k8s webhook admission metrics (${phase})"
}

# Record the webhook latency timeline over the workload window.
capture_frr_k8s_webhook_metrics_timeline() {
  if [[ "${FRR_K8S_WEBHOOK_PERF:-false}" != "true" ]]; then
    return
  fi
  local start=$1
  local end=$2
  local metrics_dir="${FRR_K8S_PERF_DIR}/metrics"
  local selector="apiserver_admission_webhook_admission_duration_seconds_bucket{name=\"${FRR_K8S_WEBHOOK_NAME}\"}"
  local pair name quantile
  mkdir -p "${metrics_dir}"

  for pair in p50:0.5 p90:0.9 p99:0.99; do
    name=${pair%%:*}
    quantile=${pair##*:}
    thanos_query_range \
      "histogram_quantile(${quantile}, sum by (le) (rate(${selector}[5m])))" \
      "${start}" "${end}" 60 > "${metrics_dir}/timeline-${name}.json" || true
  done
  thanos_query_range \
    "sum(rate(apiserver_admission_webhook_request_total{name=\"${FRR_K8S_WEBHOOK_NAME}\"}[5m]))" \
    "${start}" "${end}" 60 > "${metrics_dir}/timeline-requests.json" || true
  echo "Captured frr-k8s webhook latency timeline"
}

thanos_query() {
  local query=$1
  local timestamp=$2
  local encoded
  encoded=$(printf '%s' "${query}" | jq -sRr @uri)
  oc get --raw "/api/v1/namespaces/openshift-monitoring/services/https:thanos-querier:9091/proxy/api/v1/query?query=${encoded}&time=${timestamp}"
}

thanos_query_range() {
  local query=$1
  local start=$2
  local end=$3
  local step=$4
  local encoded
  encoded=$(printf '%s' "${query}" | jq -sRr @uri)
  oc get --raw "/api/v1/namespaces/openshift-monitoring/services/https:thanos-querier:9091/proxy/api/v1/query_range?query=${encoded}&start=${start}&end=${end}&step=${step}"
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
  E2E_REPO="${REPO_URL}" \
  ENABLE_LOCAL_INDEX="${ENABLE_LOCAL_INDEX}" \
  ES_METADATA_INDEX="${ES_METADATA_INDEX:-perf_scale_ci}" \
  ES_SERVER="${ES_SERVER}" \
  FRR_PEER_IP="${FRR_PEER_IP}" \
  GC="${GC}" \
  ITERATIONS="${ITERATIONS}" \
  JOB_NAME="${JOB_NAME:-}" \
  JOB_TYPE="${JOB_TYPE:-}" \
  KUBE_BURNER_VERSION="${KUBE_BURNER_VERSION}" \
  KUBE_BURNER_OCP_REF="${KUBE_BURNER_OCP_REF}" \
  KUBE_BURNER_OCP_REPO="${KUBE_BURNER_OCP_REPO}" \
  PROFILE_TYPE="${PROFILE_TYPE}" \
  PROW_JOB_ID="${PROW_JOB_ID:-}" \
  PULL_NUMBER="${PULL_NUMBER:-0}" \
  PPROF="${PPROF:-false}" \
  PPROF_INTERVAL="${PPROF_INTERVAL:-0}" \
  REPO_NAME="${REPO_NAME:-}" \
  REPO_OWNER="${REPO_OWNER:-}" \
  REPO_URL="${REPO_URL}" \
  UDN_BGP_LAYER2="${UDN_BGP_LAYER2:-true}" \
  UUID="${UUID}" \
)

WORKLOAD_START_EPOCH=$(date +%s)
capture_frr_k8s_webhook_metrics before "${WORKLOAD_START_EPOCH}"
start_frr_k8s_webhook_pprof

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
EXTRA_FLAGS+=" --pprof=${PPROF}"
EXTRA_FLAGS+=" --log-level=debug"
if [[ "${PPROF_INTERVAL}" != "0" ]]; then
  EXTRA_FLAGS+=" --pprof-interval=${PPROF_INTERVAL}"
fi
if [[ "${UDN_BGP_LAYER2}" == "true" ]]; then
  EXTRA_FLAGS+=" --layer2"
fi

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

WORKLOAD_END_EPOCH=$(date +%s)
stop_frr_k8s_webhook_pprof
capture_frr_k8s_webhook_metrics after "${WORKLOAD_END_EPOCH}"
capture_frr_k8s_webhook_metrics_timeline "${WORKLOAD_START_EPOCH}" "${WORKLOAD_END_EPOCH}"

METRICS_FOLDER="${BASTION_WORK_DIR}/e2e-benchmarking/workloads/kube-burner-ocp-wrapper/collected-metrics-${UUID}"
if bastion_ssh "test -f ${METRICS_FOLDER}/jobSummary.json"; then
  bastion_scp -r "${BASTION_SSH_USER}@${BASTION_HOST}:${METRICS_FOLDER}" "${ARTIFACT_DIR}/"
fi

PPROF_FOLDER="${BASTION_WORK_DIR}/e2e-benchmarking/workloads/kube-burner-ocp-wrapper/pprof-data"
if [[ "${PPROF}" == "true" ]]; then
  if bastion_ssh "test -d ${PPROF_FOLDER}"; then
    bastion_scp -r "${BASTION_SSH_USER}@${BASTION_HOST}:${PPROF_FOLDER}" "${ARTIFACT_DIR}/"
    if [[ -z "$(find "${ARTIFACT_DIR}/pprof-data" -type f -name '*.pprof' -print -quit)" ]]; then
      echo "ERROR: pprof was enabled but no pprof files were collected" >&2
      RUN_EXIT_CODE=1
    fi
  else
    echo "ERROR: pprof was enabled but ${PPROF_FOLDER} was not created" >&2
    RUN_EXIT_CODE=1
  fi
fi

exit ${RUN_EXIT_CODE}
