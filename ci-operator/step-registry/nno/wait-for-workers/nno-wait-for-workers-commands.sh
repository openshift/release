#!/bin/bash
set +x
set -euo pipefail

for marker in skip-work-steps skip-nno-precompiled; do
  if [[ -f "${SHARED_DIR}/${marker}" ]]; then
    echo "Skipping worker recovery wait: ${marker} is present."
    exit 0
  fi
done
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh" >/dev/null 2>&1 || {
    echo "ERROR: Could not load proxy configuration" >&2; exit 1;
  }
  set +x
fi

deadline=$((SECONDS + 1200))
oc() {
  local remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || return 1
  (( remaining > 15 )) && remaining=15
  # Keep internal names and URLs in raw API diagnostics out of public logs.
  command oc --request-timeout="${remaining}s" "$@" 2>/dev/null
}

# Initial reads need the same tolerance for temporary API outages as the poll loop.
snapshot() {
  local output remaining
  until output="$(oc "$@")"; do
    remaining=$((deadline - SECONDS))
    (( remaining > 0 )) || { echo "ERROR: Timed out reading initial worker recovery state" >&2; return 1; }
    echo "Waiting to read initial worker heartbeat data." >&2
    sleep "$((remaining < 10 ? remaining : 10))"
  done
  printf '%s' "${output}"
}

[[ -s "${SHARED_DIR}/nno-expected-workers" ]] || { echo "ERROR: Missing pre-transition worker inventory" >&2; exit 1; }
read -r -a workers < "${SHARED_DIR}/nno-expected-workers"
(( ${#workers[@]} > 0 )) || { echo "ERROR: Empty pre-transition worker inventory" >&2; exit 1; }

# Snapshot after firmware validation. Each kubelet must renew its own lease again;
# an unchanged Ready condition alone is not evidence of recovery.
declare -A initial_renewal
for worker in "${workers[@]}"; do
  initial_renewal["${worker}"]="$(snapshot get lease -n kube-node-lease "${worker}" --ignore-not-found -o jsonpath='{.spec.renewTime}')"
done

pending=("${workers[@]}")
while (( SECONDS < deadline )); do
  pending=()
  for worker in "${workers[@]}"; do
    if renewal="$(oc get lease -n kube-node-lease "${worker}" --ignore-not-found -o jsonpath='{.spec.renewTime}')" &&
       [[ -n "${renewal}" && "${renewal}" != "${initial_renewal[${worker}]}" ]] &&
       ready="$(oc get node "${worker}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" &&
       [[ "${ready}" == True ]]; then
      continue
    fi
    pending+=("${worker}")
  done
  if (( ${#pending[@]} == 0 )); then
    echo "All ${#workers[@]} workers have fresh heartbeats and report Ready."
    exit 0
  fi
  echo "Waiting for fresh heartbeats and Ready status: ${#pending[@]}/${#workers[@]} workers pending."
  remaining=$((deadline - SECONDS))
  (( remaining > 0 )) || break
  sleep "$((remaining < 10 ? remaining : 10))"
done

echo "ERROR: Workers did not recover within 20 minutes: ${#pending[@]}/${#workers[@]} workers pending." >&2
exit 1
