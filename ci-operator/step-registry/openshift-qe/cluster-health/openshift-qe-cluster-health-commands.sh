#!/bin/bash
set -eu

# For disconnected environments, source proxy config if available
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

ping $bastion > "${ARTIFACT_DIR}/bastion-ping-cluster-health.log" 2>&1 &

# Store the PID of the background task
BACKGROUND_PID=$!

# Run cluster health checks locally (proxied for baremetal)
oc version
oc get node -o wide
oc adm wait-for-stable-cluster --minimum-stable-period=${MINIMUM_STABLE_PERIOD} --timeout=${TIMEOUT}

# Kill the background process if it is still running
kill $BACKGROUND_PID
