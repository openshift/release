#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

echo "$(date -u --rfc-3339=seconds) - INFO: delete the DNS peering zone..."
dns_peering_zone=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" dnsPeeringZone)
cmd="gcloud dns managed-zones delete -q ${dns_peering_zone}"
run_command "${cmd}" || echo "Failed to delete dns zone '${dns_peering_zone}'."

echo "$(date -u --rfc-3339=seconds) - INFO: delete the consumer VPC network..."
consumer_network=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" consumerNetwork)
cmd="gcloud compute networks delete -q ${consumer_network}"
run_command "${cmd}" || echo "Failed to delete network '${consumer_network}'."
