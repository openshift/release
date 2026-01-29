#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

GCP_CREDENTIALS_FILE="${HYPERFLEET_E2E_PATH}/hcm-hyperfleet-e2e.json"

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
  
  gcloud auth activate-service-account --key-file="${GCP_CREDENTIALS_FILE}"
  gcloud config set project "${service_project_id}"

}

PROJECT_ID="$(jq -r -c .project_id "${GCP_CREDENTIALS_FILE}")"
gcloud_auth "$PROJECT_ID"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# In order to get the external IPs from deployed GKE cluster
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" \
    --zone="us-central1-a" \
    --project="$PROJECT_ID"

EXTERNAL_IP=$(kubectl get svc hyperfleet-api -n $NAMESPACE_NAME -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

export HYPERFLEET_API_URL=http://${EXTERNAL_IP}:8000
echo "${HYPERFLEET_API_URL}" > "${SHARED_DIR}/hyperfleet_api_url"

# Run e2e tests via --label-filter
hyperfleet-e2e test --label-filter=${LABEL_FILTER} | tee ${ARTIFACT_DIR}/results.xml
