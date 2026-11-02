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

# Setup writes namespace_name before it deploys anything. If it failed before
# that, there is nothing in the cluster to clean up.
if [[ ! -f "${SHARED_DIR}/setup_succeeded" ]] && [[ ! -f "${SHARED_DIR}/namespace_name" ]]; then
  log "Setup failed before it chose a namespace, so nothing was deployed. Skipping cleanup."
  exit 0
fi
NAMESPACE_NAME=$(cat "${SHARED_DIR}/namespace_name")

log "Cleaning up deployed resources in shared cluster"

# copy the deploy scripts to /tmp to avoid any potential permission issue when running deploy-clm.sh
cp -r /e2e/ /tmp/

cd /tmp/e2e/scripts/

helm_release_json="${SHARED_DIR}/helm-release-${NAMESPACE_NAME}.json"
# Without the release list, cleanup-k8s-resources.sh falls back to helm list
# and still deletes the namespace. Log why the list is missing.
if [[ ! -s "${helm_release_json}" ]]; then
  if [[ -f "${SHARED_DIR}/setup_succeeded" ]]; then
    log "WARNING: setup succeeded but ${helm_release_json} is missing or empty"
  else
    log "Setup failed before it saved its Helm release list, so ${helm_release_json} is missing or empty. Cleaning up namespace ${NAMESPACE_NAME} with helm list instead."
  fi
fi
./cleanup-k8s-resources.sh -f "${helm_release_json}" -n "${NAMESPACE_NAME}"
