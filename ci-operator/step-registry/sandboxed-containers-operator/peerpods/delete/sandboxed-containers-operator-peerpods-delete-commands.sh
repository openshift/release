#!/bin/bash

set -euo pipefail

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

PEERPOD_NAMESPACE="${PEERPOD_NAMESPACE:-openshift-sandboxed-containers-operator}"
PEERPOD_NAME="${PEERPOD_NAME:-tls-scan-peerpod}"

echo "Deleting peer pod ${PEERPOD_NAME}..."
oc delete "pod/${PEERPOD_NAME}" -n "${PEERPOD_NAMESPACE}" --ignore-not-found --timeout=5m
echo "Peer pod ${PEERPOD_NAME} deleted"
