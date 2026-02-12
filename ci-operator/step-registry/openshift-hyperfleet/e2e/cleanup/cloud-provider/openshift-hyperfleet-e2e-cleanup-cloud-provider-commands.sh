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

# Authenticate to Google Cloud
function gcloud_auth() {
  local service_project_id="$1"
  if ! which gcloud; then
    GCLOUD_TAR="google-cloud-cli-linux-x86_64.tar.gz"
    GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
    logger "INFO" "gcloud not installed, installing from $GCLOUD_URL"
    pushd ${HOME}
    curl -O "$GCLOUD_URL"
    tar -xzf "$GCLOUD_TAR"
    export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
    popd
  fi

  gcloud components install gke-gcloud-auth-plugin --quiet
  export USE_GKE_GCLOUD_AUTH_PLUGIN=True
  
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
  gcloud config set project "${service_project_id}"

}

PROJECT_ID="$(jq -r -c .project_id "${GOOGLE_APPLICATION_CREDENTIALS}")"
gcloud_auth "$PROJECT_ID"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
NAMESPACE_NAME=$(cat ${SHARED_DIR}/namespace_name)

log "Cleaning up Google Cloud Pub/Sub resources"
cd /e2e/deploy-scripts/
./deploy-clm.sh --action uninstall --namespace $NAMESPACE_NAME --delete-cloud-resources



