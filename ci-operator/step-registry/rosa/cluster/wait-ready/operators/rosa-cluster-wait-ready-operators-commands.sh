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

query_error=$(mktemp)
trap 'rm -f "${query_error}"' EXIT

function fail_readiness_access() {
  log "ERROR: $1"
  printf '%s\n' "$1" | tee "${ARTIFACT_DIR}/co_status.log" >> "${ARTIFACT_DIR}/co_query.log"
  exit 1
}

if [[ -z "${KUBECONFIG:-}" || ! -r "${KUBECONFIG}" || ! -s "${KUBECONFIG}" ]]; then
  fail_readiness_access "Kubeconfig is missing, empty or unreadable; refusing in-cluster credential fallback"
fi

if ! config_server=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>"${query_error}") || [[ -z "${config_server}" ]]; then
  fail_readiness_access "Kubeconfig has no usable current-context server; check the preceding credential handoff"
fi
unset config_server

function save_operator_status() {
  local output
  if output=$(oc get clusteroperators 2>"${query_error}"); then
    printf '%s\n' "${output:-No cluster operators returned.}" > "$1"
  else
    printf '%s\n' "Failed to query clusteroperators; status is unavailable, not evidence of operator failure." > "$1"
  fi
}

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
  if ! pod_output=$(oc get pods -n "${ns}" --no-headers 2>"${query_error}"); then
    log "    (pod query failed; status unavailable)"
  elif [[ -n "${pod_output}" ]]; then
    while IFS= read -r line; do
      log "    ${line}"
    done <<< "${pod_output}"
  else
    log "    (no pods returned)"
  fi

  log "  --- Recent events (last 10) ---"
  local event_output
  if ! event_output=$(oc get events -n "${ns}" --sort-by='.lastTimestamp' 2>"${query_error}" | tail -10); then
    log "    (event query failed; status unavailable)"
  elif [[ -n "${event_output}" ]]; then
    while IFS= read -r line; do
      log "    ${line}"
    done <<< "${event_output}"
  else
    log "    (no events)"
  fi
}

# Return pod lines in CrashLoopBackOff state for an operator namespace
function check_crashloop_pods() {
  local operator=$1
  local ns
  ns=$(infer_operator_namespace "${operator}")
  oc get pods -n "${ns}" --no-headers 2>/dev/null | grep -i "CrashLoopBackOff" || true
}

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
  local crashloop_consecutive=0
  local previous_crashloop_operators=""
  local query_failed=false

  log "Waiting for cluster operators: ${condition}=${desired_value} (timeout: $(( timeout / 60 ))m, poll: ${poll_interval}s)"

  while true; do
    iteration=$((iteration + 1))
    local current_time
    current_time=$(date +"%s")
    local elapsed=$(( current_time - start_time ))

    # ---- Overall timeout check ----
    if (( elapsed >= timeout )); then
      check_failed="${description}"
      if [[ "${query_failed}" == "true" ]]; then
        check_failed="Cluster operator readiness query unavailable at timeout (${condition}=${desired_value}); operator status unknown"
      fi
      log "ERROR: ${check_failed}"
      save_operator_status "${ARTIFACT_DIR}/co_status.log"
      return
    fi

    # ---- Fetch cluster operator state ----
    local co_json
    co_json=$(oc get clusteroperators -o json 2>"${query_error}") || {
      query_failed=true
      if grep -Fq 'Error from server (Forbidden)' "${query_error}"; then
        fail_readiness_access "Cluster operator query denied (Forbidden); check guest credentials and permissions"
      elif grep -Eq 'Error from server \(Unauthorized\)|You must be logged in to the server|the server has asked for the client to provide credentials' "${query_error}"; then
        fail_readiness_access "Cluster operator query denied (Unauthorized); check guest credentials and permissions"
      fi
      printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S') Cluster operator query failed (retryable or unclassified); operator status unknown." >> "${ARTIFACT_DIR}/co_query.log"
      log "WARNING: Failed to query clusteroperators, will retry in ${poll_interval}s..."
      sleep "${poll_interval}"
      continue
    }

    if ! echo "${co_json}" | jq -e --arg condition "${condition}" '
      (.items | type == "array" and length > 0) and
      all(.items[]; .status.conditions as $conditions |
        $conditions == null or (($conditions | type == "array") and
          all($conditions[]; type == "object" and
            (.type | type == "string" and length > 0) and
            (.type != $condition or
              (.status == "True" or .status == "False" or .status == "Unknown")))))' >/dev/null 2>&1; then
      fail_readiness_access "Invalid or empty cluster operator response; readiness cannot be determined"
    fi
    query_failed=false

    # ---- Identify operators that do NOT yet satisfy the condition ----
    local not_ready_operators
    not_ready_operators=$(echo "${co_json}" | jq -r \
      --arg cond "${condition}" --arg val "${desired_value}" \
      '.items[] | select(
        [.status.conditions[]? | select(.type == $cond)] |
        length == 0 or any(.[]; .status != $val)) | .metadata.name' \
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
          [.status.conditions[]? | select(.type==$cond) |
            "\(.status): \(.message // "N/A")"] |
          first // "Pending: condition not yet reported"' 2>/dev/null | head -1) || msg="(unable to read)"
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
    local crashloop_operators=""
    while IFS= read -r op; do
      [[ -z "${op}" ]] && continue
      local clb
      clb=$(check_crashloop_pods "${op}")
      if [[ -n "${clb}" ]]; then
        crashloop_operators="${crashloop_operators}${op},"
        log "  WARNING: CrashLoopBackOff detected in operator '${op}':"
        while IFS= read -r pod_line; do
          log "    ${pod_line}"
        done <<< "${clb}"
      fi
    done <<< "${not_ready_operators}"

    if [[ -n "${crashloop_operators}" ]]; then
      if [[ "${crashloop_operators}" == "${previous_crashloop_operators}" ]]; then
        crashloop_consecutive=$((crashloop_consecutive + 1))
      else
        crashloop_consecutive=1
        previous_crashloop_operators="${crashloop_operators}"
      fi

      if (( crashloop_consecutive >= 2 )); then
        local affected="${crashloop_operators%,}"
        check_failed="${description} - CrashLoopBackOff with no restart progress for 2 consecutive checks. Affected operators: ${affected}"
        log "ERROR: ${check_failed}"
        while IFS= read -r op; do
          [[ -z "${op}" ]] && continue
          collect_operator_diagnostics "${op}"
        done <<< "${not_ready_operators}"
        return
      fi
    else
      crashloop_consecutive=0
      previous_crashloop_operators=""
    fi

    # ---- Periodic artifact snapshots (every 5 iterations) ----
    if (( iteration % 5 == 0 )); then
      local snapshot_ts
      snapshot_ts=$(date "+%Y%m%d_%H%M%S")
      local snapshot_file="${ARTIFACT_DIR}/co_status_${snapshot_ts}.log"
      save_operator_status "${snapshot_file}"
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
save_operator_status "${CO_STATUS_LOG}"

if [[ -z "${check_failed}" ]]; then
  record_cluster "timers" "co_wait_time" $(( "${end_time}" - "${start_time}" ))
  log "All cluster operators done progressing after $(( ${end_time} - ${start_time} )) seconds"

  # --- Phase 2: Check Available=True (10 min) ------------------------------
  log "Phase 2: Checking cluster operators Available=True..."
  wait_for_operator_condition "Available" "True" 600 \
    "Some cluster operators are not Available"
  CO_AVAIL_LOG="${ARTIFACT_DIR}/co_available.log"
  save_operator_status "${CO_AVAIL_LOG}"
fi

if [[ -z "${check_failed}" ]]; then
  # --- Phase 3: Check Degraded=False (10 min) ------------------------------
  log "Phase 3: Checking cluster operators Degraded=False..."
  wait_for_operator_condition "Degraded" "False" 600 \
    "Some cluster operators are Degraded"
  CO_DEGRADED_LOG="${ARTIFACT_DIR}/co_degraded.log"
  save_operator_status "${CO_DEGRADED_LOG}"
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
  save_operator_status "${CO_STATUS_LOG}"
  cat "${CO_STATUS_LOG}"
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
