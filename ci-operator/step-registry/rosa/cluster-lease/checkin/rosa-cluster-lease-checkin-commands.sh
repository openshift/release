#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
CLAIM_FILE="${SHARED_DIR}/lease-claim"

if [[ ! -f "${CLAIM_FILE}" ]]; then
    log "No lease claim found (${CLAIM_FILE} does not exist). Nothing to check in."
    exit 0
fi

CM_NAME=$(cat "${CLAIM_FILE}")
if [[ -z "${CM_NAME}" ]]; then
    log "Lease claim file is empty. Nothing to check in."
    exit 0
fi

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "WARNING: Lease host kubeconfig not found. Cannot check in ${CM_NAME}."
    log "The controller will recover this cluster via stale lease detection."
    exit 0
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "Checking in lease cluster: ${CM_NAME}"

if lease_oc patch configmap "${CM_NAME}" -n "${LEASE_NAMESPACE}" --type merge -p '{
    "metadata": {
        "labels": {
            "rosa-cluster-lease/status": "available"
        },
        "annotations": {
            "rosa-cluster-lease/holder": "",
            "rosa-cluster-lease/build-id": "",
            "rosa-cluster-lease/released-at": "'"${RELEASED_AT}"'"
        }
    }
}'; then
    log "Cluster ${CM_NAME} returned to lease inventory"
else
    log "WARNING: Failed to check in ${CM_NAME}. Controller will recover it."
fi
