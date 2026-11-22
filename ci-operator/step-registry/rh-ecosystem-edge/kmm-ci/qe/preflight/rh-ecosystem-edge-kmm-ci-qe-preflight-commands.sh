#!/bin/bash

set -euo pipefail

preflight_dir="${ARTIFACT_DIR}/kmm-preflight"
mkdir -p "${preflight_dir}"

timeout_seconds="${KMM_QE_PREFLIGHT_TIMEOUT_SECONDS:-900}"
stable_period_seconds="${KMM_QE_PREFLIGHT_STABLE_PERIOD_SECONDS:-120}"
poll_seconds="${KMM_QE_PREFLIGHT_POLL_SECONDS:-30}"

collect_diagnostics() {
  local suffix="${1:-failure}"

  oc get clusteroperators -o yaml \
    >"${preflight_dir}/clusteroperators-${suffix}.yaml" 2>&1 || true
  oc get machineconfigpools -o yaml \
    >"${preflight_dir}/machineconfigpools-${suffix}.yaml" 2>&1 || true
  oc get nodes -o wide \
    >"${preflight_dir}/nodes-${suffix}.txt" 2>&1 || true
  oc get machineconfignodes -o yaml \
    >"${preflight_dir}/machineconfignodes-${suffix}.yaml" 2>&1 || true
  oc get events --all-namespaces --sort-by='.lastTimestamp' \
    >"${preflight_dir}/events-${suffix}.txt" 2>&1 || true

  oc get pods -n openshift-machine-config-operator -o wide \
    >"${preflight_dir}/mco-pods-${suffix}.txt" 2>&1 || true
  oc get pods -n openshift-machine-config-operator \
    -l k8s-app=machine-config-daemon -o name 2>/dev/null |
    while IFS= read -r pod; do
      [[ -n "${pod}" ]] || continue
      pod_name="${pod#pod/}"
      oc describe "${pod}" -n openshift-machine-config-operator \
        >"${preflight_dir}/${pod_name}-describe-${suffix}.txt" 2>&1 || true
      oc logs "${pod}" -n openshift-machine-config-operator \
        --all-containers=true --tail=300 \
        >"${preflight_dir}/${pod_name}-logs-${suffix}.txt" 2>&1 || true
    done || true
}

cluster_operators_ready() {
  oc get clusteroperators -o json | jq -e '
    (.items | length) > 0 and
    all(.items[];
      any(.status.conditions[]?; .type == "Available" and .status == "True") and
      any(.status.conditions[]?; .type == "Progressing" and .status == "False") and
      any(.status.conditions[]?; .type == "Degraded" and .status == "False")
    )
  ' >/dev/null
}

machine_config_pools_ready() {
  oc get machineconfigpools -o json | jq -e '
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
  oc get nodes -o json | jq -e '
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

  sleep "${poll_seconds}"
done

echo "KMM preflight failed after ${timeout_seconds}s; cluster was not stable" >&2
collect_diagnostics timeout
exit 1
