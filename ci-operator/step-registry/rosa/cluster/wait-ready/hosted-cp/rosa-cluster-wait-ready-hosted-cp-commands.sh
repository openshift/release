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
    # Explicit so that an interrupted sleep still ends the step with its own
    # status. A caller that inspects the return value of wait_for disables
    # errexit for this loop, which would otherwise turn a SIGTERM during the
    # sleep into an immediate, delay-free re-poll.
    sleep 60 || exit $?
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

# Sanitized failure diagnostics for the pod readiness wait.
#
# ARTIFACT_DIR is published with the publicly retained Prow job artifacts and
# the step log is public as well, so the diagnostics below are restricted to a
# closed vocabulary that cannot carry runtime values:
#   * run-local pod aliases (pod-001, ...) assigned from the UID sort order;
#     the UID itself is only used in-process to correlate events with pods and
#     is never written out
#   * allowlisted pod condition types and condition status values
#   * allowlisted pod phase, pod reason, container waiting reason and container
#     terminated reason enum values
#   * allowlisted event type and event reason enum values
#   * RFC3339 timestamps and integer counters
#   * fixed summary strings drawn from a closed set
# Anything outside an allowlist is reported as the literal "Other". Pod, node,
# container, image and object names, labels, annotations, free-text condition
# or event messages, command output, kubeconfig data and error text are never
# written to the artifact or to the log.
HCP_DIAG_MIN_EXPECTED_PODS=10
HCP_DIAG_MAX_PODS=60
HCP_DIAG_MAX_CONDITIONS_PER_POD=8
HCP_DIAG_MAX_EVENT_GROUPS_PER_POD=8
HCP_DIAG_MAX_UNMATCHED_EVENT_GROUPS=16
HCP_DIAG_MAX_INPUT_BYTES=33554432
HCP_DIAG_QUERY_TIMEOUT=60s
readonly HCP_DIAG_MIN_EXPECTED_PODS HCP_DIAG_MAX_PODS HCP_DIAG_MAX_CONDITIONS_PER_POD
readonly HCP_DIAG_MAX_EVENT_GROUPS_PER_POD HCP_DIAG_MAX_UNMATCHED_EVENT_GROUPS
readonly HCP_DIAG_MAX_INPUT_BYTES HCP_DIAG_QUERY_TIMEOUT

HCP_DIAG_CONDITION_TYPES='["PodReadyToStartContainers","Initialized","Ready","ContainersReady","PodScheduled","DisruptionTarget"]'
HCP_DIAG_CONDITION_STATUSES='["True","False","Unknown"]'
HCP_DIAG_CONDITION_REASONS='["ContainersNotInitialized","ContainersNotReady","PodCompleted","PodFailed","PodTerminating","ReadinessGatesNotReady","SchedulingGated","Unschedulable","PreemptionByScheduler","DeletionByTaintManager","DeletionByPodGC","EvictionByEvictionAPI","TerminationByKubelet"]'
HCP_DIAG_POD_PHASES='["Pending","Running","Succeeded","Failed","Unknown"]'
HCP_DIAG_POD_REASONS='["Evicted","NodeAffinity","NodeLost","Shutdown","Preempting","Terminated","UnexpectedAdmissionError","OutOfcpu","OutOfmemory","OutOfpods","OutOfephemeral-storage"]'
HCP_DIAG_WAITING_REASONS='["ContainerCreating","PodInitializing","CrashLoopBackOff","ImagePullBackOff","ErrImagePull","ErrImageNeverPull","ImageInspectError","InvalidImageName","RegistryUnavailable","SignatureValidationFailed","CreateContainerConfigError","CreateContainerError","RunContainerError","PreStartHookError","PostStartHookError","StartError","ContainerCannotRun","DeadlineExceeded","ContainerStatusUnknown"]'
HCP_DIAG_TERMINATED_REASONS='["Completed","Error","OOMKilled","ContainerCannotRun","DeadlineExceeded","Evicted","StartError","ContainerStatusUnknown","PreStartHookError","PostStartHookError"]'
HCP_DIAG_EVENT_TYPES='["Normal","Warning"]'
HCP_DIAG_EVENT_REASONS='["Scheduled","FailedScheduling","Preempted","Pulling","Pulled","Failed","InspectFailed","ErrImageNeverPull","BackOff","Created","Started","Killing","Unhealthy","ProbeWarning","FailedMount","FailedAttachVolume","FailedCreatePodSandBox","FailedCreatePodContainer","FailedPostStartHook","FailedPreStopHook","SandboxChanged","NetworkNotReady","NodeNotReady","Evicted","ExceededGracePeriod","FailedKillPod","FailedSync","OOMKilling","TaintManagerEviction","VolumeResizeFailed","FileSystemResizeFailed"]'
readonly HCP_DIAG_CONDITION_TYPES HCP_DIAG_CONDITION_STATUSES HCP_DIAG_CONDITION_REASONS
readonly HCP_DIAG_POD_PHASES HCP_DIAG_POD_REASONS HCP_DIAG_WAITING_REASONS
readonly HCP_DIAG_TERMINATED_REASONS HCP_DIAG_EVENT_TYPES HCP_DIAG_EVENT_REASONS

# Observations from the most recent readiness poll, reported separately from
# the collected pod inventory so that a poll that never saw a usable pod list
# is still distinguishable from one that saw an unhealthy pod list.
HCP_DIAG_LAST_POD_QUERY="not-run"
HCP_DIAG_LAST_POD_COUNT=0
HCP_DIAG_LAST_POD_COUNT_BELOW_MINIMUM=false

# Scratch space holds raw, unsanitized API output. Prow publishes whatever is
# left in ARTIFACT_DIR, so remove the scratch directory even if the step is
# interrupted before the collector finishes. This uses the EXIT slot and
# leaves the TERM trap installed at the top of the script alone.
HCP_DIAG_TMP_DIR=""
trap 'if [[ -n "${HCP_DIAG_TMP_DIR}" ]]; then rm -rf "${HCP_DIAG_TMP_DIR}" || true; fi' EXIT

# Classify a collected JSON document without revealing its content.
# Echoes exactly one of: ok, unavailable, malformed, oversized.
hcp_diag_classify_input() {
  local file="$1" rc="$2" size
  if [[ "${rc}" != "0" ]]; then
    echo "unavailable"
    return 0
  fi
  if [[ ! -s "${file}" ]]; then
    echo "malformed"
    return 0
  fi
  size=$(wc -c < "${file}" 2>/dev/null) || size=""
  size="${size//[[:space:]]/}"
  [[ "${size}" =~ ^[0-9]+$ ]] || size=0
  if (( size > HCP_DIAG_MAX_INPUT_BYTES )); then
    echo "oversized"
    return 0
  fi
  # --slurp so that the check applies to the same first document the renderer
  # consumes through --slurpfile, rather than to the last one in a stream.
  if ! jq -e --slurp '(length > 0) and ((.[0] | type) == "object") and (((.[0].items) | type) == "array")' "${file}" >/dev/null 2>&1; then
    echo "malformed"
    return 0
  fi
  echo "ok"
}

hcp_diag_write_jq_program() {
  cat > "$1" <<'HCP_DIAG_JQ'
def obj: if type == "object" then . else {} end;
def arr: if type == "array" then . else [] end;

def allow($set; $fallback):
  . as $v
  | if (($v | type) == "string") and (($set | index($v)) != null) then $v else $fallback end;

def allow_opt($set; $fallback):
  if . == null then null else allow($set; $fallback) end;

# \z rather than $ so that a trailing newline cannot ride along.
def ts:
  if (type == "string")
     and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z\\z")
  then . else null end;

def tally: reduce .[] as $k ({}; .[$k] = ((.[$k] // 0) + 1));

def nonneg: if (type == "number") and (. >= 0) and (. == floor) then . else 0 end;

def state_cat:
  if (type != "object") then "unknown"
  elif has("running") then "running"
  elif has("waiting") then "waiting"
  elif has("terminated") then "terminated"
  else "unknown" end;

def container_summary:
  arr as $cs
  | {
      total: ($cs | length),
      ready: ([$cs[] | obj | select(.ready == true)] | length),
      restartsTotal: ([$cs[] | obj | (.restartCount | nonneg)] | add // 0),
      restartsMax: ([$cs[] | obj | (.restartCount | nonneg)] | max // 0),
      byState: (
        ([$cs[] | obj | (.state | state_cat)] | tally) as $t
        | reduce ("running", "waiting", "terminated", "unknown") as $k ({}; .[$k] = ($t[$k] // 0))
      ),
      waitingReasons: (
        [$cs[] | obj | select((.state | state_cat) == "waiting")
         | (.state | obj | .waiting | obj | .reason) | allow($waiting_reasons; "Other")] | tally
      ),
      terminatedReasons: (
        [$cs[] | obj | select((.state | state_cat) == "terminated")
         | (.state | obj | .terminated | obj | .reason) | allow($terminated_reasons; "Other")] | tally
      )
    };

def pod_conditions:
  [ arr[] | obj
    | select((.type | type) == "string")
    | select(.type as $t | ($condition_types | index($t)) != null)
    | { type: (.type | allow($condition_types; "Other")),
        status: (.status | allow_opt($condition_statuses; "Other")),
        reason: (.reason | allow_opt($condition_reasons; "Other")),
        lastTransitionTime: (.lastTransitionTime | ts) } ]
  | .[0:$max_conditions];

def event_rows:
  [ arr[] | obj
    | select(((.involvedObject | obj | .kind) // "") == "Pod")
    | { uid: ((.involvedObject | obj | .uid) as $u | if ($u | type) == "string" then $u else null end),
        type: (.type | allow($event_types; "Other")),
        reason: (.reason | allow($event_reasons; "Other")),
        count: (if (.count | type) == "number" then (.count | nonneg) else 1 end),
        first: ((.firstTimestamp // .eventTime) | ts),
        last: ((.lastTimestamp // .eventTime) | ts) } ];

# Pods that are not ready sort first, so that the bound on the reported pod
# count drops healthy pods rather than the ones the wait failed on. The UID is
# only a deterministic tiebreak; it is never emitted.
def pod_sort_rank:
  obj as $p
  | ($p.status | obj) as $st
  | ([ ($st.conditions | arr)[] | obj | select(.type == "Ready") | .status ] | first) as $ready
  | if ($ready == "True") or ($st.phase == "Succeeded") then 1 else 0 end;

def group_events($max):
  group_by([.uid, .type, .reason])
  | map({ uid: .[0].uid,
          type: .[0].type,
          reason: .[0].reason,
          count: ([.[].count] | add // 0),
          firstTimestamp: ([.[].first | select(. != null)] | sort | first),
          lastTimestamp: ([.[].last | select(. != null)] | sort | last) })
  | sort_by([- .count, .reason, .type])
  | .[0:$max];

(($pods[0] | obj | .items) | arr) as $pods_raw
| (($events[0] | obj | .items) | arr) as $events_raw
| [ $pods_raw[] | select(type == "object") | select(((.metadata | obj | .uid) | type) == "string") ] as $valid_pods
| (($pods_raw | length) - ($valid_pods | length)) as $unparsable_pods
| ($valid_pods | sort_by([pod_sort_rank, .metadata.uid])) as $sorted_pods
| ($sorted_pods[0:$max_pods]) as $kept_pods
# Three alias digits are enough while $max_pods stays below 1000; a larger cap
# would need a wider pad to stay collision free.
| (reduce range(0; ($kept_pods | length)) as $i
     ({}; .[$kept_pods[$i].metadata.uid] = ("pod-" + (("00" + (($i + 1) | tostring)) | .[-3:])))) as $alias
| ($events_raw | event_rows) as $all_event_rows
| [ $all_event_rows[] | select(.uid as $u | if $u == null then false else ($alias | has($u)) end) ] as $matched_rows
| [ $all_event_rows[] | select(.uid as $u | if $u == null then true else (($alias | has($u)) | not) end) ] as $unmatched_rows
| ($matched_rows
   | group_by(.uid)
   | map({ key: .[0].uid, value: (group_events($max_pod_events) | map(del(.uid))) })
   | from_entries) as $pod_events
| ($unmatched_rows
   | map(.uid = null)
   | group_events($max_unmatched_events)
   | map(del(.uid))) as $unmatched_events
| [ range(0; ($kept_pods | length)) as $i
    | $kept_pods[$i] as $p
    | ($p.metadata.uid) as $uid
    | ($p | obj | .status | obj) as $st
    | { alias: $alias[$uid],
        phase: ($st.phase | allow($pod_phases; "Other")),
        reason: ($st.reason | allow_opt($pod_reasons; "Other")),
        creationTimestamp: (($p | obj | .metadata | obj | .creationTimestamp) | ts),
        startTime: ($st.startTime | ts),
        conditions: ($st.conditions | pod_conditions),
        containers: ($st.containerStatuses | container_summary),
        initContainers: ($st.initContainerStatuses | container_summary),
        events: ($pod_events[$uid] // []) } ] as $pods_out
| (($valid_pods | length) > ($kept_pods | length)) as $pods_truncated
| (($pods_out | map(.events | length) | add // 0) + ($unmatched_events | length)) as $reported_event_groups
| [ (if $pods_status != "ok" then "pod-collection-" + $pods_status else empty end),
    (if $events_status != "ok" then "event-collection-" + $events_status else empty end),
    (if $pod_query_status != "succeeded" then "last-poll-pod-query-" + $pod_query_status else empty end),
    (if $below_minimum then "last-poll-pod-count-below-minimum" else empty end),
    (if $pods_truncated then "pod-list-truncated" else empty end),
    (if $unparsable_pods > 0 then "pod-items-unparsable" else empty end) ] as $notes
| { schemaVersion: 1,
    kind: "ROSAHCPPodDiagnostics",
    trigger: "pod-readiness-wait-failed",
    collectedAt: $collected_at,
    waitTimeoutSeconds: $timeout,
    waitElapsedSeconds: $elapsed,
    minimumExpectedPods: $min_pods,
    lastPoll: { podQuery: $pod_query_status,
                podCount: $pod_count,
                podCountBelowMinimum: $below_minimum },
    collection: {
      pods: { status: $pods_status,
              observed: ($valid_pods | length),
              reported: ($kept_pods | length),
              unparsableItems: $unparsable_pods,
              truncated: $pods_truncated },
      events: { status: $events_status,
                observedPodEvents: ($all_event_rows | length),
                reportedGroups: $reported_event_groups }
    },
    summary: {
      podsByPhase: ([ $valid_pods[] | (.status | obj | .phase) | allow($pod_phases; "Other") ] | tally),
      podsNotReady: ([ $valid_pods[]
                       | ([ (.status | obj | .conditions | arr)[] | obj
                            | select(.type == "Ready") | .status ] | first) as $ready
                       | select($ready != "True") ] | length)
    },
    pods: $pods_out,
    unmatchedPodEvents: $unmatched_events,
    notes: $notes }
HCP_DIAG_JQ
}

# Best effort by contract: this never changes the step outcome and never
# propagates a failure of its own.
collect_hcp_pod_diagnostics() {
  local artifact_dir="${ARTIFACT_DIR:-}"
  local tmp_dir scratch_base pods_file events_file jq_program artifact_path
  local collected_at stamp elapsed timeout
  local pods_rc=0 events_rc=0 pods_status events_status
  local reported_pods=""

  elapsed=$(( $(date +%s) - START_TIME ))
  timeout="${HCP_READY_TIMEOUT}"
  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=0
  collected_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
  stamp=$(date -u "+%Y%m%dT%H%M%SZ")
  # Keep the "every published string is validated" invariant total, even though
  # both values come from a fixed date format.
  [[ "${collected_at}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || collected_at="1970-01-01T00:00:00Z"
  [[ "${stamp}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || stamp="19700101T000000Z"

  if [[ -z "${artifact_dir}" ]]; then
    log "Skipping HCP pod diagnostics: ARTIFACT_DIR is not set"
    return 0
  fi
  if ! mkdir -p "${artifact_dir}" 2>/dev/null; then
    log "Skipping HCP pod diagnostics: ARTIFACT_DIR cannot be created"
    return 0
  fi

  artifact_path="${artifact_dir}/rosa-hcp-pod-diagnostics-${stamp}.json"
  # mkdir -p succeeds for an existing read-only directory, so probe the exact
  # destination. Without this the later writes fail and the shell prints their
  # raw error, which must never reach the public log. The redirection is on the
  # group so that it is already in place when the file redirection is resolved.
  if ! { : > "${artifact_path}"; } 2>/dev/null; then
    log "Skipping HCP pod diagnostics: ARTIFACT_DIR is not writable"
    return 0
  fi
  # Remove the probe again so that an interrupted collection leaves no empty
  # artifact behind; the real file is only created once there is content.
  rm -f "${artifact_path}" 2>/dev/null || true
  # The scratch directory holds the raw API responses, so it must be outside
  # ARTIFACT_DIR no matter what TMPDIR says: a step killed between the query
  # and the cleanup would otherwise publish the unsanitized dumps.
  scratch_base="${TMPDIR:-/tmp}"
  case "${scratch_base%/}/" in
    "${artifact_dir%/}/"*) scratch_base="/tmp" ;;
  esac
  [[ -d "${scratch_base}" ]] || scratch_base="/tmp"
  if ! tmp_dir=$(TMPDIR="${scratch_base}" mktemp -d 2>/dev/null); then
    rm -f "${artifact_path}" 2>/dev/null || true
    log "Skipping HCP pod diagnostics: unable to create a scratch directory"
    return 0
  fi
  case "${tmp_dir%/}/" in
    "${artifact_dir%/}/"*)
      rm -rf "${tmp_dir}" 2>/dev/null || true
      rm -f "${artifact_path}" 2>/dev/null || true
      log "Skipping HCP pod diagnostics: scratch directory would be inside ARTIFACT_DIR"
      return 0
      ;;
  esac
  HCP_DIAG_TMP_DIR="${tmp_dir}"

  pods_file="${tmp_dir}/pods.json"
  events_file="${tmp_dir}/events.json"
  jq_program="${tmp_dir}/sanitize.jq"

  # Reuses the management cluster access and the exact HCP namespace that the
  # readiness checks already use; no additional credential or scope is needed.
  KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" -o json \
    --request-timeout="${HCP_DIAG_QUERY_TIMEOUT}" > "${pods_file}" 2>/dev/null || pods_rc=1
  KUBECONFIG="${MC_KUBECONFIG}" oc get events -n "${HCP_NAMESPACE}" -o json \
    --request-timeout="${HCP_DIAG_QUERY_TIMEOUT}" > "${events_file}" 2>/dev/null || events_rc=1

  pods_status=$(hcp_diag_classify_input "${pods_file}" "${pods_rc}")
  events_status=$(hcp_diag_classify_input "${events_file}" "${events_rc}")
  [[ "${pods_status}" == "ok" ]] || printf '%s' '{"items":[]}' > "${pods_file}" 2>/dev/null || true
  [[ "${events_status}" == "ok" ]] || printf '%s' '{"items":[]}' > "${events_file}" 2>/dev/null || true

  if [[ "${pods_status}" != "ok" ]]; then
    log "HCP pod diagnostics: pod collection ${pods_status}"
  fi
  if [[ "${events_status}" != "ok" ]]; then
    log "HCP pod diagnostics: event collection ${events_status}"
  fi
  if [[ "${HCP_DIAG_LAST_POD_QUERY}" != "succeeded" ]]; then
    log "HCP pod diagnostics: last readiness poll pod query ${HCP_DIAG_LAST_POD_QUERY}"
  fi
  if [[ "${HCP_DIAG_LAST_POD_COUNT_BELOW_MINIMUM}" == "true" ]]; then
    log "HCP pod diagnostics: last readiness poll counted ${HCP_DIAG_LAST_POD_COUNT} pods, below the minimum of ${HCP_DIAG_MIN_EXPECTED_PODS}"
  fi

  hcp_diag_write_jq_program "${jq_program}" 2>/dev/null || true
  if jq -n \
      --slurpfile pods "${pods_file}" \
      --slurpfile events "${events_file}" \
      --arg collected_at "${collected_at}" \
      --arg pods_status "${pods_status}" \
      --arg events_status "${events_status}" \
      --arg pod_query_status "${HCP_DIAG_LAST_POD_QUERY}" \
      --argjson pod_count "${HCP_DIAG_LAST_POD_COUNT}" \
      --argjson below_minimum "${HCP_DIAG_LAST_POD_COUNT_BELOW_MINIMUM}" \
      --argjson min_pods "${HCP_DIAG_MIN_EXPECTED_PODS}" \
      --argjson elapsed "${elapsed}" \
      --argjson timeout "${timeout}" \
      --argjson max_pods "${HCP_DIAG_MAX_PODS}" \
      --argjson max_conditions "${HCP_DIAG_MAX_CONDITIONS_PER_POD}" \
      --argjson max_pod_events "${HCP_DIAG_MAX_EVENT_GROUPS_PER_POD}" \
      --argjson max_unmatched_events "${HCP_DIAG_MAX_UNMATCHED_EVENT_GROUPS}" \
      --argjson condition_types "${HCP_DIAG_CONDITION_TYPES}" \
      --argjson condition_statuses "${HCP_DIAG_CONDITION_STATUSES}" \
      --argjson condition_reasons "${HCP_DIAG_CONDITION_REASONS}" \
      --argjson pod_phases "${HCP_DIAG_POD_PHASES}" \
      --argjson pod_reasons "${HCP_DIAG_POD_REASONS}" \
      --argjson waiting_reasons "${HCP_DIAG_WAITING_REASONS}" \
      --argjson terminated_reasons "${HCP_DIAG_TERMINATED_REASONS}" \
      --argjson event_types "${HCP_DIAG_EVENT_TYPES}" \
      --argjson event_reasons "${HCP_DIAG_EVENT_REASONS}" \
      -f "${jq_program}" > "${tmp_dir}/diagnostics.json" 2>/dev/null \
     && mv "${tmp_dir}/diagnostics.json" "${artifact_path}" 2>/dev/null; then
    reported_pods=$(jq -r '.collection.pods.reported' "${artifact_path}" 2>/dev/null) || reported_pods=""
    [[ "${reported_pods}" =~ ^[0-9]+$ ]] || reported_pods=0
    log "Wrote sanitized HCP pod diagnostics for ${reported_pods} pods to ${artifact_path##*/}"
  else
    # Only values from the closed sets above are interpolated here, and
    # podCount is emitted through %d so that the result is always valid JSON.
    { printf '{"schemaVersion":1,"kind":"ROSAHCPPodDiagnostics","trigger":"pod-readiness-wait-failed","collectedAt":"%s","collection":{"pods":{"status":"%s"},"events":{"status":"%s"}},"lastPoll":{"podQuery":"%s","podCount":%d,"podCountBelowMinimum":%s},"pods":[],"unmatchedPodEvents":[],"notes":["diagnostics-rendering-failed"]}\n' \
      "${collected_at}" "${pods_status}" "${events_status}" \
      "${HCP_DIAG_LAST_POD_QUERY}" "${HCP_DIAG_LAST_POD_COUNT}" "${HCP_DIAG_LAST_POD_COUNT_BELOW_MINIMUM}" \
      > "${artifact_path}"; } 2>/dev/null || true
    log "HCP pod diagnostics: rendering failed, wrote a status-only artifact to ${artifact_path##*/}"
  fi

  rm -rf "${tmp_dir}" 2>/dev/null || true
  HCP_DIAG_TMP_DIR=""
  return 0
}

# 3. Check pod status in HCP namespace
check_pods() {
  local pod_list
  HCP_DIAG_LAST_POD_QUERY="failed"
  HCP_DIAG_LAST_POD_COUNT=0
  HCP_DIAG_LAST_POD_COUNT_BELOW_MINIMUM=false
  pod_list=$(KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" --no-headers 2>/dev/null) || return 1
  HCP_DIAG_LAST_POD_QUERY="succeeded"
  # `echo "" | wc -l` is 1, which the published counter must not report as a
  # pod. The comparison below is unchanged either way: both 0 and 1 are under
  # the minimum, so an empty list still fails exactly as it did before.
  if [[ -z "${pod_list}" ]]; then
    HCP_DIAG_LAST_POD_COUNT=0
  else
    HCP_DIAG_LAST_POD_COUNT=$(( $(echo "${pod_list}" | wc -l) ))
  fi
  if (( HCP_DIAG_LAST_POD_COUNT < HCP_DIAG_MIN_EXPECTED_PODS )); then
    HCP_DIAG_LAST_POD_COUNT_BELOW_MINIMUM=true
    log "Too few pods found, expected at least ${HCP_DIAG_MIN_EXPECTED_PODS}"
    return 1
  fi
  NOT_READY=$(echo "${pod_list}" | grep -v -E "Running|Completed|Succeeded" || true)
  [[ -z "${NOT_READY}" ]]
}
if ! wait_for "all pods ready in ${HCP_NAMESPACE}" check_pods; then
  collect_hcp_pod_diagnostics || true
  exit 1
fi
KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" -o wide || true

# 4. Check VpcEndpoint 'private-hcp' in HCP namespace
check_vpce() {
  VPCE_STATUS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get vpcendpoints.avo.openshift.io private-hcp -n "${HCP_NAMESPACE}" \
    -o jsonpath='{.status.status}' 2>/dev/null) || return 1
  [[ "${VPCE_STATUS}" == "available" ]]
}
wait_for "VpcEndpoint 'private-hcp' in ${HCP_NAMESPACE}" check_vpce

log "All HostedControlPlane readiness checks passed"
