#!/bin/bash
set -uo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -f "${SHARED_DIR}/kubeconfig" ]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

SLEEP_HOURS="${DEBUG_SLEEP_HOURS:-6}"
SLEEP_SECS=$((SLEEP_HOURS * 3600))

echo "=== Debug-on-failure step ==="
echo "Checking if the cluster is reachable and if a failure occurred..."

if ! oc get nodes &>/dev/null; then
    echo "Cluster is not reachable — skipping debug sleep"
    exit 0
fi

echo "Cluster is reachable."
echo "This step sleeps ${SLEEP_HOURS}h to allow live debugging of the failed cluster."
echo "Cluster API: $(oc whoami --show-server 2>/dev/null || echo unknown)"
echo "Nodes:"
oc get nodes -o wide 2>/dev/null || true
echo ""
echo "=== Sleeping ${SLEEP_HOURS} hours (${SLEEP_SECS}s) for live debugging ==="
echo "Sleep started at: $(date -u)"
echo "Sleep will end at: $(date -u -d "+${SLEEP_HOURS} hours" 2>/dev/null || date -u)"
sleep "${SLEEP_SECS}"
echo "Debug sleep completed at: $(date -u)"
