#!/bin/bash

set -euo pipefail
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

BASE_DOMAIN="$(cat ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"


CLUSTER_IP=$(gcloud compute instances list --filter="name=${INSTANCE_PREFIX}" --format json | jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP')
BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"
gcloud dns record-sets create "${INSTANCE_PREFIX}.${BASE_DOMAIN}." --rrdatas "${CLUSTER_IP}"  --ttl 60 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}"-external \
  --network "${INSTANCE_PREFIX}" \
  --allow tcp:80,tcp:443,tcp:6443
