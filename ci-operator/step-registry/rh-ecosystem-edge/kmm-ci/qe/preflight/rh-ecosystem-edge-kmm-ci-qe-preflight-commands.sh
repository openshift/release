#!/bin/bash

set -euo pipefail

preflight_dir="${ARTIFACT_DIR}/kmm-preflight"
mkdir -p "${preflight_dir}"

timeout_seconds="${KMM_QE_PREFLIGHT_TIMEOUT_SECONDS:-900}"
stable_period_seconds="${KMM_QE_PREFLIGHT_STABLE_PERIOD_SECONDS:-120}"
poll_seconds="${KMM_QE_PREFLIGHT_POLL_SECONDS:-30}"
diagnostic_budget_seconds="${KMM_QE_PREFLIGHT_DIAGNOSTIC_BUDGET_SECONDS:-120}"
diagnostic_command_timeout_seconds="${KMM_QE_PREFLIGHT_DIAGNOSTIC_COMMAND_TIMEOUT_SECONDS:-30}"

if ! command -v timeout >/dev/null 2>&1; then
  echo "KMM preflight requires the timeout command for bounded diagnostics" >&2
  exit 1
fi

collect_diagnostics() {
  local suffix="${1:-failure}"
  local diagnostics_deadline=$(( $(date +%s) + diagnostic_budget_seconds ))

  run_diagnostic() {
    local output="$1"
    shift
    local remaining=$(( diagnostics_deadline - $(date +%s) ))
    local command_timeout="${diagnostic_command_timeout_seconds}"

    if (( remaining <= 0 )); then
      echo "Diagnostic budget exhausted before: $*" >"${output}"
      return 0
    fi
    if (( command_timeout > remaining )); then
      command_timeout="${remaining}"
    fi

    timeout --signal=TERM "${command_timeout}s" "$@" >"${output}" 2>&1 || true
  }

  run_diagnostic "${preflight_dir}/clusteroperators-${suffix}.yaml" \
    oc get clusteroperators -o yaml
  run_diagnostic "${preflight_dir}/machineconfigpools-${suffix}.yaml" \
    oc get machineconfigpools -o yaml
  run_diagnostic "${preflight_dir}/nodes-${suffix}.txt" \
    oc get nodes -o wide
  run_diagnostic "${preflight_dir}/machineconfignodes-${suffix}.yaml" \
    oc get machineconfignodes -o yaml
  run_diagnostic "${preflight_dir}/events-${suffix}.txt" \
    oc get events --all-namespaces --sort-by='.lastTimestamp'

  run_diagnostic "${preflight_dir}/mco-pods-${suffix}.txt" \
    oc get pods -n openshift-machine-config-operator -o wide

  local pod_names_file="${preflight_dir}/mco-pod-names-${suffix}.txt"
  run_diagnostic "${pod_names_file}" \
    oc get pods -n openshift-machine-config-operator \
      -l k8s-app=machine-config-daemon -o name
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    local pod_name
    pod_name="${pod#pod/}"
    run_diagnostic "${preflight_dir}/${pod_name}-describe-${suffix}.txt" \
      oc describe "${pod}" -n openshift-machine-config-operator
    run_diagnostic "${preflight_dir}/${pod_name}-logs-${suffix}.txt" \
      oc logs "${pod}" -n openshift-machine-config-operator \
        --all-containers=true --tail=300
  done <"${pod_names_file}"
}

remaining_seconds() {
  local remaining=$(( deadline - $(date +%s) ))
  if (( remaining < 1 )); then
    echo 1
  else
    echo "${remaining}"
  fi
}

cluster_operators_ready() {
  local request_timeout
  request_timeout="$(remaining_seconds)"
  oc --request-timeout="${request_timeout}s" get clusteroperators -o json | jq -e '
    (.items | length) > 0 and
    all(.items[];
      any(.status.conditions[]?; .type == "Available" and .status == "True") and
      any(.status.conditions[]?; .type == "Progressing" and .status == "False") and
      any(.status.conditions[]?; .type == "Degraded" and .status == "False")
    )
  ' >/dev/null
}

machine_config_pools_ready() {
  local request_timeout
  request_timeout="$(remaining_seconds)"
  oc --request-timeout="${request_timeout}s" get machineconfigpools -o json | jq -e '
    (.items | length) > 0 and
    all(.items[];
      (.status.machineCount == .status.updatedMachineCount) and
      (.status.machineCount == .status.readyMachineCount) and
      ((.status.degradedMachineCount // 0) == 0) and
      any(.status.conditions[]?; .type == "Updated" and .status == "True") and
      any(.status.conditions[]?; .type == "Updating" and .status == "False") and
      any(.status.conditions[]?; .type == "Degraded" and .status == "False")
    )
  ' >/dev/null
}

nodes_ready() {
  local request_timeout
  request_timeout="$(remaining_seconds)"
  oc --request-timeout="${request_timeout}s" get nodes -o json | jq -e '
    (.items | length) > 0 and
    all(.items[];
      any(.status.conditions[]?; .type == "Ready" and .status == "True")
    )
  ' >/dev/null
}

deadline=$(( $(date +%s) + timeout_seconds ))
stable_since=""
last_state=""

while (( $(date +%s) < deadline )); do
  state=""
  if ! cluster_operators_ready; then
    state+=" clusteroperators"
  fi
  if ! machine_config_pools_ready; then
    state+=" machineconfigpools"
  fi
  if ! nodes_ready; then
    state+=" nodes"
  fi

  now="$(date +%s)"
  if [[ -z "${state}" ]]; then
    if [[ -z "${stable_since}" ]]; then
      stable_since="${now}"
      echo "KMM preflight: cluster is healthy; starting ${stable_period_seconds}s stability window"
    fi
    if (( now - stable_since >= stable_period_seconds )); then
      echo "KMM preflight passed after $((now - stable_since))s of stable cluster health"
      exit 0
    fi
  else
    stable_since=""
    if [[ "${state}" != "${last_state}" ]]; then
      echo "KMM preflight waiting for:${state}"
      last_state="${state}"
    fi
  fi

  remaining="$(remaining_seconds)"
  sleep_for="${poll_seconds}"
  if (( sleep_for > remaining )); then
    sleep_for="${remaining}"
  fi
  sleep "${sleep_for}"
done

echo "KMM preflight failed after ${timeout_seconds}s; cluster was not stable" >&2
collect_diagnostics timeout
exit 1
