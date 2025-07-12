#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

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