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
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
if [[ -n "${BASE_DOMAIN}" ]]; then
  GCP_BASE_DOMAIN="${BASE_DOMAIN}"
fi

GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
if [[ -n "${BASE_DOMAIN_ZONE_PROJECT}" ]]; then
  GCP_PROJECT="${BASE_DOMAIN_ZONE_PROJECT}"
fi

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GCP_PROJECT}"
fi

if [[ -n "${BASE_DOMAIN_ZONE_NAME}" ]]; then
  GCP_BASE_DOMAIN_ZONE_NAME="${BASE_DOMAIN_ZONE_NAME}"
else
  GCP_BASE_DOMAIN_ZONE_NAME=$(gcloud dns managed-zones list --filter="dnsName=${GCP_BASE_DOMAIN}." --format='value(name)')
fi

INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"
API_IP=$(gcloud compute forwarding-rules describe "${INFRA_ID}-apiserver" --global --format json | jq -r .IPAddress)
if [[ -z "${API_IP}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the API server IP address, abort."
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - INFO: Adding external DNS record-sets for API server..."
CMD="gcloud --project ${GCP_PROJECT} dns record-sets create api.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}. --rrdatas=${API_IP} --ttl 300 --type A --zone ${GCP_BASE_DOMAIN_ZONE_NAME}"
echo "Running Command: ${CMD}"
eval "${CMD}"

cat > "${SHARED_DIR}/api-records-destroy.sh" << EOF
gcloud --project ${GCP_PROJECT} dns record-sets delete -q api.${CLUSTER_NAME}.${GCP_BASE_DOMAIN}. --type A --zone ${GCP_BASE_DOMAIN_ZONE_NAME}
EOF
