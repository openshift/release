#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKLOAD=${WORKLOAD:?}
UUID=${UUID:-$(uuidgen)}
SWEEP_SLEEP=${SWEEP_SLEEP:-30}
SWEEP_CLEANUP_TIMEOUT=${SWEEP_CLEANUP_TIMEOUT:-300}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for tool in jq oc timeout setsid; do
  command -v "$tool" >/dev/null || fail "Sweep requires $tool"
done
[[ ! $WORKLOAD =~ index ]] || fail "QPS sweeps do not support index workloads"
[[ $UUID =~ ^[a-zA-Z0-9]([a-zA-Z0-9_.-]*[a-zA-Z0-9])?$ ]] || fail "UUID must be a Kubernetes label value"
[[ $SWEEP_SLEEP =~ ^(0|[1-9][0-9]*)$ ]] || fail "SWEEP_SLEEP must be nonnegative integer seconds"
[[ $SWEEP_CLEANUP_TIMEOUT =~ ^[1-9][0-9]*$ ]] || fail "SWEEP_CLEANUP_TIMEOUT must be positive integer seconds"
if [[ ${BURST+x} ]]; then
  [[ $BURST =~ ^[1-9][0-9]*$ ]] || fail "BURST must be a positive integer"
fi
# Split the list on whitespace without expanding pathname patterns.
read -r -a qps_values <<< "${QPS_LIST//$'\n'/ }"
((${#qps_values[@]})) || fail "QPS_LIST must contain positive integers"
declare -A seen=()
for qps in "${qps_values[@]}"; do
  [[ $qps =~ ^[1-9][0-9]*$ ]] || fail "Invalid QPS: $qps"
  [[ ! ${seen[$qps]+yes} ]] || fail "Duplicate QPS: $qps"
  seen[$qps]=1
  ((${#UUID} + ${#qps} + 4 <= 63)) || fail "Step UUID exceeds the Kubernetes label limit"
done

summary="sweep-${UUID}.json"
[[ ! -e $summary ]] || fail "$summary already exists; use a new UUID"
for qps in "${qps_values[@]}"; do
  [[ ! -e sweep-${UUID}-qps${qps}.log && ! -e collected-metrics-${UUID}-qps${qps} ]] || fail "Step artifacts already exist; use a new UUID"
done
printf '[]\n' > "$summary"
step_uuid=""
child=""
active=false

cleanup() {
  timeout --kill-after=5s "${SWEEP_CLEANUP_TIMEOUT}s" \
    oc --request-timeout=10s delete namespaces -l "kube-burner.io/uuid=${step_uuid}" \
    --ignore-not-found --wait=true --timeout="${SWEEP_CLEANUP_TIMEOUT}s"
}

record() {
  local status
  if jq --arg workload "$WORKLOAD" --arg uuid "$step_uuid" \
    --argjson qps "$qps" --argjson burst "$burst" \
    --argjson start_epoch "$start" --argjson end_epoch "$(date +%s)" \
    --argjson rc "$rc" --argjson cleanup_rc "$cleanup_rc" --arg log "$log" \
    '. + [{workload: $workload, qps: $qps, burst: $burst, uuid: $uuid,
           start_epoch: $start_epoch, end_epoch: $end_epoch, rc: $rc,
           cleanup_rc: $cleanup_rc, log: $log}]' "$summary" > "${summary}.tmp" &&
    mv "${summary}.tmp" "$summary"; then
    return 0
  else
    status=$?
    rm -f "${summary}.tmp"
    return "$status"
  fi
}

finish() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  if [[ -n $child ]]; then
    # Stop the entire wrapper process group before deleting its namespaces.
    kill -TERM -- "-$child" 2>/dev/null || true
    kill -KILL -- "-$child" 2>/dev/null || true
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  if $active; then
    rc=$status
    cleanup_rc=0
    cleanup >> "$log" 2>&1 || cleanup_rc=$?
    record || echo "ERROR: Could not record interrupted step" >&2
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for qps in "${qps_values[@]}"; do
  step_uuid="${UUID}-qps${qps}"
  burst=${BURST-$qps}
  log="sweep-${step_uuid}.log"
  start=$(date +%s)
  active=true
  echo "Running $WORKLOAD QPS=$qps BURST=$burst UUID=$step_uuid (log: $log)"
  # Keep the existing command construction, metrics flags and indexing per step.
  setsid env QPS_LIST= QPS="$qps" BURST="$burst" UUID="$step_uuid" \
    bash "${SCRIPT_DIR}/run.sh" "$@" > "$log" 2>&1 &
  child=$!
  rc=0
  wait "$child" || rc=$?
  child=""
  cleanup_rc=0
  cleanup >> "$log" 2>&1 || cleanup_rc=$?
  active=false
  record
  ((rc == 0)) || exit "$rc"
  ((cleanup_rc == 0)) || exit "$cleanup_rc"
  if [[ $qps != "${qps_values[-1]}" ]]; then
    sleep "$SWEEP_SLEEP"
  fi
done
