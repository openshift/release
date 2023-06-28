#!/bin/bash

set -eo pipefail

INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

function teardown() {
  # This is for running the gcloud commands
  mock-nss.sh
  gcloud auth activate-service-account \
    --quiet --key-file "${CLUSTER_PROFILE_DIR}/gce.json"
  gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
  gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
  gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

  set -x
  set +e

  echo "Deprovisioning cluster ..."
  gcloud compute instances delete "${INSTANCE_PREFIX}" --quiet
  gcloud compute firewall-rules delete "${INSTANCE_PREFIX}" --quiet
  gcloud compute networks subnets delete "${INSTANCE_PREFIX}" --quiet
  gcloud compute networks delete "${INSTANCE_PREFIX}" --quiet
}

trap 'teardown' EXIT
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
