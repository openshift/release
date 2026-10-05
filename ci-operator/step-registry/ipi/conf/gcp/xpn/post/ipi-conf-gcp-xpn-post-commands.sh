#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="openshift-dev-installer"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
fi
gcloud config set project "${GOOGLE_PROJECT_ID}"

echo "$(date -u --rfc-3339=seconds) - Destroying GCP Subnets for Host Project..."

REGION="${LEASED_RESOURCE}"
INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
HOST_PROJECT_CONTROL_SUBNET="${INSTANCE_PREFIX}-subnet-1"
HOST_PROJECT_COMPUTE_SUBNET="${INSTANCE_PREFIX}-subnet-2"
HOST_PROJECT_NETWORK="${INSTANCE_PREFIX}-vpc"
NAT_NAME="${INSTANCE_PREFIX}-nat"

gcloud compute firewall-rules delete "${INSTANCE_PREFIX}"
gcloud compute routers nats delete "${NAT_NAME}" --router="${INSTANCE_PREFIX}" --region="${REGION}"
gcloud compute routers delete "${INSTANCE_PREFIX}" --region "${REGION}"
gcloud compute networks subnets delete "${HOST_PROJECT_CONTROL_SUBNET}" --region "${REGION}"
gcloud compute networks subnets delete "${HOST_PROJECT_COMPUTE_SUBNET}" --region "${REGION}"
gcloud compute networks delete "${HOST_PROJECT_NETWORK}"
