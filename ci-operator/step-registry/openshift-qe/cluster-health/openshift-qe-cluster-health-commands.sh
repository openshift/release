#!/bin/bash
set -eu

# For disconnected environments, source proxy config if available
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Run cluster health checks locally (proxied for baremetal)
oc version
oc get node -o wide
oc adm wait-for-stable-cluster --minimum-stable-period=${MINIMUM_STABLE_PERIOD} --timeout=${TIMEOUT}

