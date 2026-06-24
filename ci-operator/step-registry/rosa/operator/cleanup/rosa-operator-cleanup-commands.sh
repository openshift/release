#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

CLUSTER_PACKAGE_NAME=""

if [[ -n "${SHARED_DIR:-}" ]]; then
    CLUSTER_PACKAGE_NAME=$(cat "${SHARED_DIR}/operator-e2e-clusterpackage" 2>/dev/null || true)
fi

if [[ -z "${CLUSTER_PACKAGE_NAME}" ]]; then
    log "No ClusterPackage to clean up"
    exit 0
fi

log "Cleaning up test operator resources"

if oc get clusterpackage "${CLUSTER_PACKAGE_NAME}" &>/dev/null; then
    log "Deleting ClusterPackage ${CLUSTER_PACKAGE_NAME}"
    oc delete clusterpackage "${CLUSTER_PACKAGE_NAME}" --timeout=120s || true
fi

log "Cleanup complete"
