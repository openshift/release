#!/bin/bash
#
# Debugging aid: sleep for DEBUG_SLEEP_DURATION seconds so that the CI clusters
# remain alive (and accessible) after test steps finish but before the post-phase
# uninstall/deprovision steps tear everything down.
#
# Set DEBUG_SLEEP_DURATION=0 to skip entirely (default for normal runs).
# Set DEBUG_SLEEP_DURATION=7200 (2h) or any positive integer for debugging runs.
#
set -euo pipefail; shopt -s inherit_errexit

typeset -i sleepSecs="${DEBUG_SLEEP_DURATION}"

if (( sleepSecs <= 0 )); then
    : "DEBUG_SLEEP_DURATION=0 — skipping debug sleep"
    exit 0
fi

# ── Print cluster access hints ──────────────────────────────────────────────
: "=== DEBUG SLEEP: clusters will remain alive for ${sleepSecs}s ==="

# Hub kubeconfig
if [[ -f "${KUBECONFIG}" ]]; then
    : "Hub kubeconfig : ${KUBECONFIG}"
fi

# Spoke kubeconfigs
typeset -i i
for (( i = 1; ; i++ )); do
    typeset kcPath="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
    [[ -f "${kcPath}" ]] || break
    typeset clusterNameFile="${SHARED_DIR}/managed-cluster-name-${i}"
    typeset clusterName="spoke-${i}"
    [[ -f "${clusterNameFile}" ]] && clusterName="$(cat "${clusterNameFile}")"
    : "Spoke ${i} (${clusterName}) kubeconfig : ${kcPath}"
done

typeset endTime
endTime="$(date -d "+${sleepSecs} seconds" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || date -v "+${sleepSecs}S" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || echo "unknown")"
: "Sleeping until approximately ${endTime} ..."

sleep "${sleepSecs}"
: "=== DEBUG SLEEP complete ==="
