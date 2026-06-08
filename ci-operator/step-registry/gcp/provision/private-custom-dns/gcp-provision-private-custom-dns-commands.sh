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

function run_command() {
  local CMD="$1"
  echo "$(date -u --rfc-3339=seconds) - Running command: ${CMD}"
  eval "${CMD}"
}

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
GCP_REGION="${LEASED_RESOURCE}"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
if [[ -n "${BASE_DOMAIN}" ]]; then
  GCP_BASE_DOMAIN="${BASE_DOMAIN}"
fi

GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GCP_PROJECT}"
fi

INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"

#Getting the IP address of the internal API LB
INTERNAL_API_LB_IP=$(gcloud compute forwarding-rules describe "${INFRA_ID}-api-internal" --project=$GCP_PROJECT --region ${GCP_REGION} --format json | jq -r .IPAddress)
if [[ -z "${INTERNAL_API_LB_IP}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the internal API server IP address, abort."
  exit 1
fi

echo "api.${CLUSTER_NAME}.${GCP_BASE_DOMAIN} ${INTERNAL_API_LB_IP}" | tee -a "${SHARED_DIR}/custom_dns"

set +e
#Get the ingress LB IP 
WORKER_SUBNET_NAME="${CLUSTER_NAME}-worker-subnet"
INGRESS_LB_IP=$(gcloud compute forwarding-rules list --project=$GCP_PROJECT --filter="subnetwork:(projects/$GCP_PROJECT/regions/$GCP_REGION/subnetworks/$WORKER_SUBNET_NAME)" --format="json" | jq -r '.[].IPAddress' )
if [[ -z "${INGRESS_LB_IP}" ]]; then
  CMD="gcloud compute target-pools list --format='value(name)' --filter=\"instances~${INFRA_ID}\""
  run_command "${CMD}"
  random_id=$(gcloud compute target-pools list --format='value(name)' --filter="instances~${INFRA_ID}" | grep -v "${INFRA_ID}")
  if [ -z "${random_id}" ]; then
    CMD="gcloud compute backend-services list --format='value(name)' --filter=\"backends.group~${INFRA_ID}\""
    run_command "${CMD}"
    random_id=$(gcloud compute backend-services list --format='value(name)' --filter="backends.group~${INFRA_ID}" | grep -v "${INFRA_ID}")
  fi
  if [ -n "${random_id}" ]; then
    CMD="gcloud compute forwarding-rules describe ${random_id} --project=$GCP_PROJECT --region ${GCP_REGION} --format=json"
    run_command "${CMD}"
    INGRESS_LB_IP=$(gcloud compute forwarding-rules describe ${random_id} --project=$GCP_PROJECT --region ${GCP_REGION} --format="json" | jq -r '.IPAddress')
  fi
  if [[ -z "${INGRESS_LB_IP}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to find the Ingress internal IP address, abort."
    exit 1
  fi
fi
set -e

echo "apps.${CLUSTER_NAME}.${GCP_BASE_DOMAIN} ${INGRESS_LB_IP}" | tee -a "${SHARED_DIR}/custom_dns"

echo "$(date -u --rfc-3339=seconds) - INFO: The content of '${SHARED_DIR}/custom_dns'"
cat "${SHARED_DIR}/custom_dns"
