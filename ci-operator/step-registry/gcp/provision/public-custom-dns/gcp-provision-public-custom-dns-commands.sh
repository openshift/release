#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function find_out_api_and_ingress_ip_addresses() {
  local -r infra_id="$1"
  local -r region="$2"
  local -r cluster_domain="$3"
  local -r out_file="$4"
  local api_ip_address ingress_ip_address ingress_forwarding_rule

  api_ip_address=$(gcloud compute forwarding-rules describe --global "${infra_id}-apiserver" --format json | jq -r .IPAddress)
  if [[ -z "${api_ip_address}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the API forwarding-rule."
    ret=1
  fi

  ingress_forwarding_rule=$(gcloud compute target-pools list --format=json --filter="instances[]~${infra_id}" | jq -r .[].name)
  if [[ -n "${ingress_forwarding_rule}" ]]; then
    ingress_ip_address=$(gcloud compute forwarding-rules describe --region "${region}" "${ingress_forwarding_rule}" --format json | jq -r .IPAddress)
  else
    ingress_ip_address=""
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the INGRESS forwarding-rule."
    ret=1
  fi

  echo "$(date -u --rfc-3339=seconds) - INFO: Populate the file '${out_file}' with API server IP (${api_ip_address}) and INGRESS server IP (${ingress_ip_address})..."
  cat > "${out_file}"  << EOF
api.${cluster_domain}. ${api_ip_address}
*.apps.${cluster_domain}. ${ingress_ip_address}
EOF
}

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
if [[ -n "${BASE_DOMAIN}" ]]; then
  GCP_BASE_DOMAIN="${BASE_DOMAIN}"
fi

cluster_name=${NAMESPACE}-${UNIQUE_HASH}
cluster_domain="${cluster_name}.${GCP_BASE_DOMAIN}"
INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi
GCP_REGION="${LEASED_RESOURCE}"

ret=0
find_out_api_and_ingress_ip_addresses "${INFRA_ID}" "${GCP_REGION}" "${cluster_domain}" "${SHARED_DIR}/public-custom-dns"

echo "$(date -u --rfc-3339=seconds) - INFO: See '${SHARED_DIR}/public-custom-dns'."
exit "${ret}"