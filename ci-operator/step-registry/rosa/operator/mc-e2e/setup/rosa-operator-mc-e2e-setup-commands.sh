#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
if [[ ! -f "${MC_KUBECONFIG}" ]]; then
    log "ERROR: MC kubeconfig not found at ${MC_KUBECONFIG}"
    log "rosa-cluster-credentials-hypershift-mgmt may have failed"
    exit 1
fi

cp "${MC_KUBECONFIG}" "${SHARED_DIR}/kubeconfig"
log "MC kubeconfig set for operator e2e"
KUBECONFIG="${SHARED_DIR}/kubeconfig" oc whoami
log "Connected to MC: $(KUBECONFIG="${SHARED_DIR}/kubeconfig" oc whoami --show-server)"
