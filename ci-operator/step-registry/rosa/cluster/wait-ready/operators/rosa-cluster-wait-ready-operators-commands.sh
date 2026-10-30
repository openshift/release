#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

OPERATOR_STALL_TIMEOUT=${OPERATOR_STALL_TIMEOUT:-1800}
OPERATOR_POLL_INTERVAL=${OPERATOR_POLL_INTERVAL:-120}

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}
set_proxy

# Infer the most likely namespace for a cluster operator.
# Most operators follow the "openshift-<name>" convention; known
# exceptions are mapped explicitly.
function infer_operator_namespace() {
  local operator=$1
  case "${operator}" in
    kube-apiserver)                             echo "openshift-kube-apiserver" ;;
    kube-controller-manager)                    echo "openshift-kube-controller-manager" ;;
    kube-scheduler)                             echo "openshift-kube-scheduler" ;;
    kube-storage-version-migrator)              echo "openshift-kube-storage-version-migrator" ;;
    openshift-apiserver)                        echo "openshift-apiserver" ;;
    openshift-controller-manager)               echo "openshift-controller-manager" ;;
    openshift-samples)                          echo "openshift-cluster-samples-operator" ;;
    service-ca)                                 echo "openshift-service-ca" ;;
    etcd)                                       echo "openshift-etcd" ;;
    cloud-credential)                           echo "openshift-cloud-credential-operator" ;;
    machine-api)                                echo "openshift-machine-api" ;;
    cluster-autoscaler)                         echo "openshift-machine-api" ;;
    image-registry)                             echo "openshift-image-registry" ;;
    operator-lifecycle-manager)                 echo "openshift-operator-lifecycle-manager" ;;
    operator-lifecycle-manager-catalog)         echo "openshift-operator-lifecycle-manager" ;;
    operator-lifecycle-manager-packageserver)   echo "openshift-operator-lifecycle-manager" ;;
    *)                                          echo "openshift-${operator}" ;;
  esac
}

# Collect pod status and recent events for a degraded/stuck operator
function collect_operator_diagnostics() {
  local operator=$1
  local ns
  ns=$(infer_operator_namespace "${operator}")

  log "  Diagnostics for operator '${operator}' (namespace: ${ns}):"
  log "  --- Pod status ---"
  local pod_output
  pod_output=$(oc get pods -n "${ns}" --no-headers 2>/dev/null) || true
  if [[ -n "${pod_output}" ]]; then
    while IFS= read -r line; do
      log "    ${line}"
    done <<< "${pod_output}"
  else
    log "    (namespace ${ns} not found or no pods)"
  fi

  log "  --- Recent events (last 10) ---"
  local event_output
  event_output=$(oc get events -n "${ns}" --sort-by='.lastTimestamp' 2>/dev/null | tail -10) || true
  if [[ -n "${event_output}" ]]; then
    while IFS= read -r line; do
      log "    ${line}"
    done <<< "${event_output}"
  else
    log "    (no events)"
  fi
}

# Return normalized CrashLoopBackOff container observations for an operator namespace
function check_crashloop_pods() {
  set +x
  local operator=$1
  local ns
  ns=$(infer_operator_namespace "${operator}")
  local remaining=$(( readiness_deadline - $(date +%s) ))
  (( remaining > 10 )) && remaining=10
  (( remaining > 0 )) || return 1
  timeout --kill-after=1s "${remaining}s" oc get pods -n "${ns}" --request-timeout="${remaining}s" -o json 2>/dev/null |
    head -c 1048576 | jq -ce '
      if (.items | type) != "array" then error("missing pod list") else . end |
      [.items[] |
        if (.metadata | type) != "object" then error("invalid pod metadata") else . end |
        .metadata as $pod |
        ((.status.initContainerStatuses // []) + (.status.containerStatuses // []) +
          (.status.ephemeralContainerStatuses // [])) as $statuses |
        {complete: (($statuses | length) > 0), crashes: [$statuses[] |
        select(.state.waiting.reason == "CrashLoopBackOff") |
        if ($pod.uid | type) != "string" or ($pod.name | type) != "string" or
          (.name | type) != "string" or (.restartCount | type) != "number" or .restartCount < 0
        then error("incomplete crash status") else
          {uid: $pod.uid, pod: $pod.name, container: .name, restarts: .restartCount,
           containerID: (.containerID // ""),
           finishedAt: (.lastState.terminated.finishedAt // ""),
           exitCode: .lastState.terminated.exitCode, signal: .lastState.terminated.signal,
           oomKilled: (.lastState.terminated.reason == "OOMKilled")}
        end]}] as $observations |
      {complete: all($observations[]; .complete),
       crashes: ([$observations[].crashes[]] | sort_by(.uid, .container))}'
}

function crash_diagnostic_command() {
  local remaining=$(( readiness_deadline - $(date +%s) ))
  local budget=$(( diagnostic_deadline - $(date +%s) ))
  (( remaining > budget )) && remaining=${budget}
  (( remaining > 5 )) && remaining=5
  (( remaining > 0 )) || return 1
  timeout --kill-after=1s "${remaining}s" oc "$@" --request-timeout="${remaining}s" 2>/dev/null
}

function collect_crash_diagnostics() (
  set +x
  local operator=$1
  local crashes=$2
  local destination=$3
  local ns
  ns=$(infer_operator_namespace "${operator}")
  mkdir -p "${destination}" || return 0
  printf '%s\n' "${crashes}" | jq -c --arg operator "${operator}" --arg namespace "${ns}" '
    def identity($limit):
      if type == "string" and length <= $limit and
        test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$") then . else "[omitted]" end;
    [.[:4][] | {index: null,
      operator: ($operator | identity(253)), namespace: ($namespace | identity(63)),
      pod: (.pod | identity(253)), podUID: (.uid | identity(64)),
      container: (.container | identity(63)), restarts, waitingReason: "CrashLoopBackOff",
      lastTermination: {finishedAt: (if (.finishedAt | type) == "string" and
          (.finishedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
          then .finishedAt else null end),
        exitCode: (if (.exitCode | type) == "number" then .exitCode else null end),
        signal: (if (.signal | type) == "number" then .signal else null end), oomKilled}}] |
    to_entries | map(.value + {index: .key})' | head -c 65536 > "${destination}/status.json" || true
  if ! crash_diagnostic_command get events -n "${ns}" --field-selector=type=Warning -o json |
      head -c 1048576 | jq -c '
        [.items | sort_by(.lastTimestamp // .eventTime // "") | .[-10:][] |
          {reason: (if .reason == "BackOff" or .reason == "Unhealthy" or .reason == "Killing"
            then .reason else "Other" end), count: (if (.count | type) == "number" then .count else null end)}]' |
      head -c 65536 > "${destination}/events.json"; then
    printf '%s\n' '{"unavailable":true}' > "${destination}/events.json"
  fi
  local pod container index=0 previous
  while IFS=$'\t' read -r pod container; do
    [[ -n "${pod}" && -n "${container}" ]] || continue
    for previous in previous current; do
      local previous_flag=()
      [[ "${previous}" == previous ]] && previous_flag=(--previous)
      if ! crash_diagnostic_command logs "${pod}" -n "${ns}" -c "${container}" \
          "${previous_flag[@]}" --tail=100 --limit-bytes=16384 |
          head -c 16384 | LC_ALL=C awk '
            { label="[content omitted]" }
            /panic:/ { label="panic: [content omitted]" }
            /fatal error:/ { label="fatal error: [content omitted]" }
            /segmentation fault/ { label="segmentation fault: [content omitted]" }
            { print NR ": " label }' | head -c 16384 > "${destination}/container-${index}-${previous}.log"; then
        printf '%s\n' '[log unavailable or truncated]' > "${destination}/container-${index}-${previous}.log"
      fi
    done
    index=$((index + 1))
  done < <(printf '%s\n' "${crashes}" | jq -r '.[:4][] | [.pod, .container] | @tsv')
  return 0
)

# ---------------------------------------------------------------------------
# wait_for_operator_condition
#
# Polls cluster operators until all satisfy <condition>=<desired_value>,
# or a timeout / stall / deterministic failure is detected.
#
# Arguments:
#   $1 - condition name  (e.g. "Progressing")
#   $2 - desired value   (e.g. "False")
#   $3 - timeout seconds (e.g. 3600)
#   $4 - failure description used in check_failed on timeout
#
# Side-effects:
#   Sets the global "check_failed" variable on failure.
# ---------------------------------------------------------------------------
function wait_for_operator_condition() {
  local condition=$1
  local desired_value=$2
  local timeout=$3
  local description=$4
  local poll_interval=${OPERATOR_POLL_INTERVAL}

  local start_time
  start_time=$(date +"%s")
  local previous_not_ready_set=""
  local stall_start_time=${start_time}
  local iteration=0
  local crashloop_stall_start=""
  local crashloop_stall_window=$(( 300 + poll_interval ))
  local previous_crashloop_state=""
  local readiness_deadline=$(( start_time + timeout ))
  local diagnostic_budget=40 diagnostic_deadline=0
  local diagnostic_captures=0

  log "Waiting for cluster operators: ${condition}=${desired_value} (timeout: $(( timeout / 60 ))m, poll: ${poll_interval}s)"

  while true; do
    iteration=$((iteration + 1))
    local current_time
    current_time=$(date +"%s")
    local elapsed=$(( current_time - start_time ))

    # ---- Overall timeout check ----
    if (( elapsed >= timeout )); then
      check_failed="${description}"
      log "ERROR: ${check_failed}"
      oc get clusteroperators 2>/dev/null || true
      return
    fi

    # ---- Fetch cluster operator state ----
    local co_json
    co_json=$(oc get clusteroperators -o json 2>/dev/null) || {
      previous_crashloop_state=""
      crashloop_stall_start=""
      log "WARNING: Failed to query clusteroperators, will retry in ${poll_interval}s..."
      sleep "${poll_interval}"
      continue
    }

    # ---- Identify operators that do NOT yet satisfy the condition ----
    local not_ready_operators
    not_ready_operators=$(echo "${co_json}" | jq -r \
      --arg cond "${condition}" --arg val "${desired_value}" \
      '.items[] | select(.status.conditions[]? |
        select(.type==$cond and .status!=$val)) | .metadata.name' \
      2>/dev/null | sort) || true

    local not_ready_count=0
    if [[ -n "${not_ready_operators}" ]]; then
      not_ready_count=$(echo "${not_ready_operators}" | wc -l)
    fi

    # ---- All done? ----
    if [[ "${not_ready_count}" -eq 0 ]]; then
      log "All cluster operators satisfy ${condition}=${desired_value} after $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
      return
    fi

    # ---- Log per-operator condition messages ----
    log "Iteration ${iteration}: ${not_ready_count} operator(s) with ${condition}!=${desired_value} [elapsed: $(( elapsed / 60 ))m $(( elapsed % 60 ))s]"

    while IFS= read -r op; do
      [[ -z "${op}" ]] && continue
      local msg
      msg=$(echo "${co_json}" | jq -r \
        --arg name "${op}" --arg cond "${condition}" \
        '.items[] | select(.metadata.name==$name) |
          .status.conditions[] | select(.type==$cond) |
          "\(.status): \(.message // "N/A")"' 2>/dev/null | head -1) || msg="(unable to read)"
      log "  ${op}: ${condition}=${msg}"
    done <<< "${not_ready_operators}"

    # ---- Stall detection ----
    local current_not_ready_set
    current_not_ready_set=$(echo "${not_ready_operators}" | tr '\n' ',' | sed 's/,$//')

    if [[ "${current_not_ready_set}" == "${previous_not_ready_set}" ]]; then
      local stall_elapsed=$(( current_time - stall_start_time ))
      if (( stall_elapsed >= OPERATOR_STALL_TIMEOUT )); then
        check_failed="${description} - stalled for $(( stall_elapsed / 60 )) minutes with no progress. Stuck operators: ${current_not_ready_set}"
        log "ERROR: ${check_failed}"
        while IFS= read -r op; do
          [[ -z "${op}" ]] && continue
          collect_operator_diagnostics "${op}"
        done <<< "${not_ready_operators}"
        return
      fi
      log "  (same set unchanged for $(( stall_elapsed / 60 ))m - stall timeout: $(( OPERATOR_STALL_TIMEOUT / 60 ))m)"
    else
      # The set changed — reset the stall timer
      stall_start_time=${current_time}
      previous_not_ready_set="${current_not_ready_set}"
    fi

    # ---- Per-operator diagnostics for Degraded operators ----
    if [[ "${condition}" == "Progressing" ]]; then
      local degraded_operators
      degraded_operators=$(echo "${co_json}" | jq -r \
        '.items[] | select(.status.conditions[]? |
          select(.type=="Degraded" and .status=="True")) | .metadata.name' \
        2>/dev/null | sort) || true

      if [[ -n "${degraded_operators}" ]]; then
        log "  WARNING: The following operators report Degraded=True:"
        while IFS= read -r op; do
          [[ -z "${op}" ]] && continue
          local deg_msg
          deg_msg=$(echo "${co_json}" | jq -r \
            --arg name "${op}" \
            '.items[] | select(.metadata.name==$name) |
              .status.conditions[] | select(.type=="Degraded") |
              .message // "N/A"' 2>/dev/null | head -1) || deg_msg="(unable to read)"
          log "    ${op}: ${deg_msg}"
          collect_operator_diagnostics "${op}"
        done <<< "${degraded_operators}"
      fi
    fi

    # ---- Early exit: CrashLoopBackOff with no restart progress ----
    local crashloop_operators="" crashloop_state="" crashloop_queries_ok=true
    while IFS= read -r op; do
      [[ -z "${op}" ]] && continue
      local clb_result clb
      if ! clb_result=$(check_crashloop_pods "${op}"); then
        crashloop_queries_ok=false
        log "  WARNING: Pod crash status unavailable for operator '${op}'; not evidence of restart stagnation"
        continue
      fi
      clb=$(jq -c '.crashes' <<< "${clb_result}")
      if ! jq -e '.complete' <<< "${clb_result}" >/dev/null; then
        crashloop_queries_ok=false
        log "  WARNING: Incomplete pod observation for operator '${op}'; restart stagnation evidence reset"
      fi
      if [[ "${clb}" != '[]' ]]; then
        crashloop_operators="${crashloop_operators}${op},"
        crashloop_state="${crashloop_state}${op}:${clb}"
        log "  WARNING: CrashLoopBackOff detected in operator '${op}' (restart activity is not readiness)"
        if (( diagnostic_captures < 8 && diagnostic_budget > 0 )); then
          diagnostic_captures=$((diagnostic_captures + 1))
          local capture_start
          capture_start=$(date +%s)
          diagnostic_deadline=$(( capture_start + diagnostic_budget ))
          collect_crash_diagnostics "${op}" "${clb}" \
            "${ARTIFACT_DIR}/crash-${condition}-${iteration}-${diagnostic_captures}" || true
          diagnostic_budget=$(( diagnostic_budget - $(date +%s) + capture_start ))
        fi
      fi
    done <<< "${not_ready_operators}"

    if [[ -n "${crashloop_operators}" && "${crashloop_queries_ok}" == true ]]; then
      local crashloop_observed_at
      crashloop_observed_at=$(date +%s)
      if [[ "${crashloop_state}" != "${previous_crashloop_state}" ]]; then
        crashloop_stall_start=${crashloop_observed_at}
      fi
      previous_crashloop_state="${crashloop_state}"
      local crashloop_stall_elapsed=$(( crashloop_observed_at - crashloop_stall_start ))

      if (( crashloop_stall_elapsed > crashloop_stall_window )); then
        local affected="${crashloop_operators%,}"
        check_failed="${description} - CrashLoopBackOff with no restart progress observed for ${crashloop_stall_elapsed}s (required >${crashloop_stall_window}s). Affected operators: ${affected}"
        log "ERROR: ${check_failed}"
        while IFS= read -r op; do
          [[ -z "${op}" ]] && continue
          collect_operator_diagnostics "${op}"
        done <<< "${not_ready_operators}"
        return
      fi
    else
      crashloop_stall_start=""
      previous_crashloop_state=""
    fi

    # ---- Periodic artifact snapshots (every 5 iterations) ----
    if (( iteration % 5 == 0 )); then
      local snapshot_ts
      snapshot_ts=$(date "+%Y%m%d_%H%M%S")
      local snapshot_file="${ARTIFACT_DIR}/co_status_${snapshot_ts}.log"
      oc get clusteroperators > "${snapshot_file}" 2>&1 || true
      log "  Artifact snapshot saved: co_status_${snapshot_ts}.log"
    fi

    sleep "${poll_interval}"
  done
}

# ===========================================================================
# Main
# ===========================================================================
check_failed=""

# --- Phase 1: Wait for Progressing=False (60 min) --------------------------
log "Phase 1: Wait for cluster operators to stop progressing..."
start_time=$(date +"%s")
wait_for_operator_condition "Progressing" "False" 3600 \
  "Cluster operators not done progressing within 60m"
end_time=$(date +"%s")

# Persist final CO status for artifact collection
CO_STATUS_LOG="${ARTIFACT_DIR}/co_status.log"
oc get clusteroperators > "${CO_STATUS_LOG}" 2>&1 || true

if [[ -z "${check_failed}" ]]; then
  record_cluster "timers" "co_wait_time" $(( "${end_time}" - "${start_time}" ))
  log "All cluster operators done progressing after $(( ${end_time} - ${start_time} )) seconds"

  # --- Phase 2: Check Available=True (10 min) ------------------------------
  log "Phase 2: Checking cluster operators Available=True..."
  wait_for_operator_condition "Available" "True" 600 \
    "Some cluster operators are not Available"
  CO_AVAIL_LOG="${ARTIFACT_DIR}/co_available.log"
  oc get clusteroperators > "${CO_AVAIL_LOG}" 2>&1 || true
fi

if [[ -z "${check_failed}" ]]; then
  # --- Phase 3: Check Degraded=False (10 min) ------------------------------
  log "Phase 3: Checking cluster operators Degraded=False..."
  wait_for_operator_condition "Degraded" "False" 600 \
    "Some cluster operators are Degraded"
  CO_DEGRADED_LOG="${ARTIFACT_DIR}/co_degraded.log"
  oc get clusteroperators > "${CO_DEGRADED_LOG}" 2>&1 || true
fi

if [[ -z "${check_failed}" ]]; then
  log "All cluster operators are Available, not Progressing, and not Degraded"

  # Optionally clear the ClusterVersion channel so the CVO does not attempt to retrieve
  # updates. CI clusters on nightly payloads have no valid update graph, causing the CVO
  # retrieval timestamp to go stale. After ~1h the CannotRetrieveUpdatesSRE alert fires,
  # which openshift-tests flags as an unknown alert and fails the conformance run.
  # Clearing the channel sets reason=NoChannel on the RetrievedUpdates condition,
  # which the alert expression explicitly excludes.
  if [[ "${CLEAR_CLUSTERVERSION_CHANNEL:-}" == "true" ]]; then
    log "Clearing ClusterVersion channel to prevent CannotRetrieveUpdatesSRE alert..."
    oc patch clusterversion version --type merge -p '{"spec":{"channel":""}}' || true
  fi
fi

if [[ -n "${check_failed}" ]]; then
  echo "ERROR: ${check_failed}"
  oc get clusteroperators
  if [[ -e "${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url" ]]; then
    echo "Meet operator issue. Sleep 3h to call debugging."
    CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
    slack_hook_url=$(cat "${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url")
    slack_message='{"text": "'"${check_failed}"' for cluster '"${CLUSTER_ID}"'. Sleep 3 hours for debugging with the job '"${JOB_NAME}/${BUILD_ID}"'. <!subteam^S0BEMESJS83>"}'
    curl -X POST -H 'Content-type: application/json' --data "${slack_message}" "${slack_hook_url}"
    sleep 10800
  fi
  exit 1
fi
