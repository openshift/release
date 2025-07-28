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

if [[ -z "${PRIVATE_SERVICE_CONNECT_ADDRESS}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: The given private server connect address is empty, abort. " && exit 1
fi

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

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  NETWORK="$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json")"
fi

if [[ -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  NETWORK=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.network')
fi

if [[ -z "${NETWORK}" ]]; then
  echo "Could not find VPC network" && exit 1
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
REGION="${LEASED_RESOURCE}"
gcp_custom_endpoint="${CLUSTER_NAME//-/}"

echo "$(date -u --rfc-3339=seconds) - Creating the address for Private Service Connect..."
CMD="gcloud compute addresses create ${CLUSTER_NAME}-psc-address --global --purpose=PRIVATE_SERVICE_CONNECT --addresses=${PRIVATE_SERVICE_CONNECT_ADDRESS} --network=${NETWORK}"
run_command "${CMD}"

echo "$(date -u --rfc-3339=seconds) - Creating the forwarding-rule (i.e. custom endpoint) for Private Service Connect..."
CMD="gcloud compute forwarding-rules create ${gcp_custom_endpoint} --global --network=${NETWORK} --address=${CLUSTER_NAME}-psc-address --target-google-apis-bundle=all-apis --service-directory-registration=projects/${GOOGLE_PROJECT_ID}/locations/${REGION}"
run_command "${CMD}"

echo "$(date -u --rfc-3339=seconds) - Briefly checking the forwarding-rule (i.e. custom endpoint) and the DNS zone p.googleapis.com..."
CMD="gcloud compute forwarding-rules list --filter target=\"(all-apis OR vpc-sc)\" --global"
run_command "${CMD}"
CMD="gcloud dns managed-zones list | grep p.googleapis.com"
run_command "${CMD}"
zone_name=$(gcloud dns managed-zones list | grep p.googleapis.com | grep "${CLUSTER_NAME}" | awk '{print $1}')
if [[ -n "${zone_name}" ]]; then
  CMD="gcloud dns managed-zones describe ${zone_name}"
  run_command "${CMD}"
else
  echo "$(date -u --rfc-3339=seconds) - INFO: something wrong, failed to find the p.googleapis.com zone. "
fi

cat > "${SHARED_DIR}/gcp_custom_endpoint" << EOF
${gcp_custom_endpoint}
EOF

cat > "${SHARED_DIR}/gcp_custom_endpoint_ip_address" << EOF
${PRIVATE_SERVICE_CONNECT_ADDRESS}
EOF
