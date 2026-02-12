#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
export GOOGLE_APPLICATION_CREDENTIALS="${HYPERFLEET_E2E_CREDENTIALS_PATH}/hcm-hyperfleet-e2e.json"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
NAMESPACE_NAME=$(cat ${SHARED_DIR}/namespace_name)

log "Cleaning up deployed resources in shared cluster"
cd /e2e/deploy-scripts/
./deploy-clm.sh --action uninstall --namespace $NAMESPACE_NAME --delete-k8s-resources 



