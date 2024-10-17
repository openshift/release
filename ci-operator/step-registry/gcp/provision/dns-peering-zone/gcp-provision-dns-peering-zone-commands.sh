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

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

dns_sa=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" serviceAccount)
target_project=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" targetProject)
target_network=$(yq-go r "${SHARED_DIR}/dns-peering-zone-settings.yaml" targetNetwork)

echo "$(date -u --rfc-3339=seconds) - INFO: create consumer VPC network..."
consumer_network="${CLUSTER_NAME}-consumer-network"
cmd="gcloud compute networks create ${consumer_network} --subnet-mode=custom 2>/dev/null"
run_command "${cmd}"
cat <<EOF >>"${SHARED_DIR}/dns-peering-zone-settings.yaml"
consumerNetwork: ${consumer_network}
EOF

echo "$(date -u --rfc-3339=seconds) - INFO: create DNS peering zone..."
dns_peering_zone="${CLUSTER_NAME}-dns-peering-zone"
cmd="gcloud dns managed-zones create ${dns_peering_zone} --description=\"for OCPBUGS-38719 testing\" --dns-name=${CLUSTER_NAME}.${GCP_BASE_DOMAIN}. --networks=${CLUSTER_NAME}-consumer-network --account=${dns_sa} --target-network=${target_network} --target-project=${target_project} --visibility=private"
run_command "${cmd}"
cat <<EOF >>"${SHARED_DIR}/dns-peering-zone-settings.yaml"
dnsPeeringZone: ${dns_peering_zone}
EOF

cmd="gcloud dns managed-zones describe ${dns_peering_zone}"
run_command "${cmd}"