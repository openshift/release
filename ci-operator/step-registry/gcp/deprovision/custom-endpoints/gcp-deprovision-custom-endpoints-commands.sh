#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
gcp_custom_endpoint="${CLUSTER_NAME//-/}"

echo "$(date -u --rfc-3339=seconds) - Deleting the forwarding-rule (i.e. custom endpoint)..."
CMD="gcloud compute forwarding-rules delete -q ${gcp_custom_endpoint} --global"
run_command "${CMD}"

echo "$(date -u --rfc-3339=seconds) - Deleting the address for Private Service Connect..."
CMD="gcloud compute addresses delete -q ${CLUSTER_NAME}-psc-address --global"
run_command "${CMD}"