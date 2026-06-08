#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

POOL_NAMESPACE="${POOL_NAMESPACE:-rosa-pool}"
POOL_HOST_KUBECONFIG="/etc/rosa-pool-manager/kubeconfig"
CLAIM_FILE="${SHARED_DIR}/pool-claim"

if [[ ! -f "${CLAIM_FILE}" ]]; then
    log "No pool claim found (${CLAIM_FILE} does not exist). Nothing to check in."
    exit 0
fi

CM_NAME=$(cat "${CLAIM_FILE}")
if [[ -z "${CM_NAME}" ]]; then
    log "Pool claim file is empty. Nothing to check in."
    exit 0
fi

if [[ ! -f "${POOL_HOST_KUBECONFIG}" ]]; then
    log "WARNING: Pool host kubeconfig not found. Cannot check in ${CM_NAME}."
    log "The health check job will recover this cluster via stale lease detection."
    exit 0
fi

pool_oc() {
    oc --kubeconfig="${POOL_HOST_KUBECONFIG}" "$@"
}

RELEASED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "Checking in pool cluster: ${CM_NAME}"

# Patch the ConfigMap back to available
if pool_oc patch configmap "${CM_NAME}" -n "${POOL_NAMESPACE}" --type merge -p '{
    "metadata": {
        "labels": {
            "rosa-pool/status": "available"
        },
        "annotations": {
            "rosa-pool/holder": "",
            "rosa-pool/build-id": "",
            "rosa-pool/released-at": "'"${RELEASED_AT}"'"
        }
    }
}'; then
    log "Cluster ${CM_NAME} returned to pool"
else
    log "WARNING: Failed to check in ${CM_NAME}. Health check will recover it."
fi
