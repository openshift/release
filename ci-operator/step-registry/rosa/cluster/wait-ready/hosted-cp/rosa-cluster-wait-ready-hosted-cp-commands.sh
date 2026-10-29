#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${*}\033[0m"
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log into OCM
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# Get cluster info
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_INFO=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}")
CLUSTER_NAME=$(echo "${CLUSTER_INFO}" | jq -r '.name')
log "Cluster ID: ${CLUSTER_ID}"
log "Cluster name: ${CLUSTER_NAME}"

# Get management cluster info
log "Retrieving management cluster info..."
MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/provision_shard | jq -r '.management_cluster')
if [[ -z "${MC_NAME}" || "${MC_NAME}" == "null" ]]; then
  log "ERROR: Failed to get management cluster name for cluster ${CLUSTER_ID}"
  exit 1
fi
log "Management cluster name: ${MC_NAME}"

MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id')
if [[ -z "${MC_CLUSTER_ID}" || "${MC_CLUSTER_ID}" == "null" ]]; then
  log "ERROR: Failed to get management cluster ID for ${MC_NAME}"
  exit 1
fi
log "Management cluster ID: ${MC_CLUSTER_ID}"

# Get MC kubeconfig
log "Fetching management cluster kubeconfig..."
MC_KUBECONFIG="${SHARED_DIR}/hcp-mc.kubeconfig"
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r '.kubeconfig' > "${MC_KUBECONFIG}"
$WAS_TRACING && set -x

if ! KUBECONFIG="${MC_KUBECONFIG}" oc whoami &>/dev/null; then
  log "ERROR: MC kubeconfig validation failed (oc whoami failed)"
  exit 1
fi
log "Management cluster access established"

# Determine namespaces
# HC namespace:  ocm-<env>-<cluster_id>
# HCP namespace: ocm-<env>-<cluster_id>-<cluster_name>
# The namespace env token is the OCM short name, which differs from OCM_LOGIN_ENV:
# integration -> int (staging and production match their login env verbatim).
case "${OCM_LOGIN_ENV}" in
  integration) NS_ENV="int" ;;
  *)           NS_ENV="${OCM_LOGIN_ENV}" ;;
esac
HC_NAMESPACE="ocm-${NS_ENV}-${CLUSTER_ID}"
HCP_NAMESPACE="ocm-${NS_ENV}-${CLUSTER_ID}-${CLUSTER_NAME}"
log "HC namespace:  ${HC_NAMESPACE}"
log "HCP namespace: ${HCP_NAMESPACE}"

# Global timeout tracking
START_TIME=$(date +%s)

wait_for() {
  local description="$1"
  shift
  log "Checking ${description}..."
  while true; do
    if "$@"; then
      log "PASSED: ${description}"
      return 0
    fi
    elapsed=$(( $(date +%s) - START_TIME ))
    if (( elapsed >= HCP_READY_TIMEOUT )); then
      log "ERROR: Timed out after ${HCP_READY_TIMEOUT}s waiting for: ${description}"
      return 1
    fi
    log "WAITING: ${description} (elapsed: ${elapsed}s), retrying in 60s..."
    sleep 60
  done
}

# 1. Check HostedCluster CR status in HC namespace
check_hostedcluster() {
  HC_AVAILABLE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || return 1
  HC_DEGRADED=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null) || return 1
  [[ "${HC_AVAILABLE}" == "True" && "${HC_DEGRADED}" != "True" ]]
}
wait_for "HostedCluster '${CLUSTER_NAME}' in ${HC_NAMESPACE}" check_hostedcluster

# 2. Check HostedControlPlane CR status in HCP namespace
check_hostedcontrolplane() {
  HCP_AVAILABLE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcontrolplane "${CLUSTER_NAME}" -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || return 1
  HCP_READY=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcontrolplane "${CLUSTER_NAME}" -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.status.ready}' 2>/dev/null) || return 1
  HCP_DEGRADED=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcontrolplane "${CLUSTER_NAME}" -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null) || return 1
  [[ "${HCP_AVAILABLE}" == "True" && "${HCP_READY}" == "true" && "${HCP_DEGRADED}" != "True" ]]
}
wait_for "HostedControlPlane '${CLUSTER_NAME}' in ${HCP_NAMESPACE}" check_hostedcontrolplane

# 3. Check pod status in HCP namespace
POD_LIST_ERROR=""

pod_api_error() {
  case "${1}" in
    *Forbidden*|*forbidden*) echo "Forbidden" ;;
    *Unauthorized*|*unauthorized*) echo "Unauthorized" ;;
    *timed\ out*|*timeout*|*Timeout*|*deadline\ exceeded*) echo "Timeout" ;;
    *x509:*|*TLS*) echo "TLS error" ;;
    *connection\ refused*|*no\ such\ host*) echo "Connection error" ;;
    *) echo "API request failed (details omitted)" ;;
  esac
}

diagnose_pods() (
  set +x
  local sanitize='
    def allowed($values): . as $value | if $value == null then null
      elif ($values | index($value)) != null then $value else "Other" end;
    def numeric: if type == "number" then . else null end;
    def reason: allowed(["BackOff", "Completed", "ContainerCannotRun", "ContainerCreating",
      "ContainersNotReady", "CrashLoopBackOff", "CreateContainerConfigError", "CreateContainerError",
      "DeadlineExceeded", "DisruptionTarget", "ErrImageNeverPull", "ErrImagePull", "Error", "Evicted",
      "Failed", "FailedAttachVolume", "FailedBinding", "FailedCreatePodSandBox", "FailedKillPod",
      "FailedMapVolume", "FailedMount", "FailedPostStartHook", "FailedPreStopHook", "FailedScheduling",
      "FailedSync", "FailedToRetrieveImagePullSecret", "ImagePullBackOff", "InvalidImageName",
      "Killing", "NetworkNotReady", "NodeNotReady", "OOMKilled", "PodCompleted", "PodInitializing",
      "RunContainerError", "SchedulingGated", "Shutdown", "UnexpectedAdmissionError", "Unhealthy",
      "Unschedulable"]);
    def timestamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$")
      then . else null end;'
  log "Pod readiness failure diagnostics (up to 100 pods and 20 warning events; identities/messages omitted; unknown values are Other)"
  if [[ -n "${POD_LIST_ERROR}" ]]; then
    log "Last pod-list API error: ${POD_LIST_ERROR}"
  fi
  if ! KUBECONFIG="${MC_KUBECONFIG}" timeout --kill-after=5s 20s oc get pods -n "${HCP_NAMESPACE}" \
    --request-timeout=15s -o json 2>/dev/null | head -c 1048576 | jq -c "${sanitize}"'
      def containers:
        [(. // []) | to_entries[] | .key as $index | .value | {index: $index, ready: (.ready == true), restartCount: (.restartCount | numeric),
          waitingReason: (.state.waiting.reason | reason),
          terminated: (.state.terminated | if . then {reason: (.reason | reason), exitCode: (.exitCode | numeric), signal: (.signal | numeric)} else null end),
          lastTermination: (.lastState.terminated | if . then {reason: (.reason | reason), exitCode: (.exitCode | numeric), signal: (.signal | numeric)} else null end)}][:20];
      {totalPods: (.items | length), pods: [.items | sort_by(any(.status.conditions[]?;
        .type == "Ready" and .status == "True")) | .[:100] | to_entries[] | .key as $index | .value |
        {index: $index, phase: (.status.phase | allowed(["Pending", "Running", "Succeeded", "Failed", "Unknown"])),
         conditions: [.status.conditions[]? | {type: (.type | allowed(["Ready", "Initialized", "PodScheduled",
           "ContainersReady", "PodReadyToStartContainers", "DisruptionTarget"])),
           status: (.status | allowed(["True", "False", "Unknown"])), reason: (.reason | reason)}][:20],
         initContainers: (.status.initContainerStatuses | containers),
         containers: (.status.containerStatuses | containers)}]}' 2>/dev/null; then
    log "Pod diagnostics unavailable (request failed, timed out, or exceeded 1 MiB)"
  fi
  if ! KUBECONFIG="${MC_KUBECONFIG}" timeout --kill-after=5s 20s oc get events -n "${HCP_NAMESPACE}" \
    --request-timeout=15s --field-selector=involvedObject.kind=Pod,type=Warning -o json 2>/dev/null \
    | head -c 1048576 | jq -c "${sanitize}"'
      {warningEvents: [.items | sort_by(.lastTimestamp // .eventTime // .metadata.creationTimestamp) |
        .[-20:][] | {reason: (.reason | reason), count: (.count | numeric),
          lastObserved: (.lastTimestamp // .eventTime // .metadata.creationTimestamp | timestamp)}]}' 2>/dev/null; then
    log "Event diagnostics unavailable (request failed, timed out, or exceeded 1 MiB)"
  fi
)

check_pods() {
  local pod_list pod_error_file status was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  set +x
  pod_error_file=$(mktemp) || return 1
  if pod_list=$(KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" \
    --no-headers 2>"${pod_error_file}"); then
    rm -f "${pod_error_file}"
    $was_tracing && set -x
  else
    status=$?
    POD_LIST_ERROR="$(pod_api_error "$(head -c 4096 "${pod_error_file}")") (exit ${status})"
    rm -f "${pod_error_file}"
    $was_tracing && set -x
    return 1
  fi
  if (( $(echo "${pod_list}" | wc -l) < 10 )); then
    log "Too few pods found, expected at least 10"
    return 1
  fi
  NOT_READY=$(echo "${pod_list}" | grep -v -E "Running|Completed|Succeeded" || true)
  [[ -z "${NOT_READY}" ]]
}
pod_readiness_exit() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    diagnose_pods || true
  fi
  exit "${status}"
}
trap pod_readiness_exit EXIT
wait_for "all pods ready in ${HCP_NAMESPACE}" check_pods
trap - EXIT
KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" -o wide || true

# 4. Check VpcEndpoint 'private-hcp' in HCP namespace
check_vpce() {
  VPCE_STATUS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get vpcendpoints.avo.openshift.io private-hcp -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.status.status}' 2>/dev/null) || return 1
  [[ "${VPCE_STATUS}" == "available" ]]
}
wait_for "VpcEndpoint 'private-hcp' in ${HCP_NAMESPACE}" check_vpce

log "All HostedControlPlane readiness checks passed"
