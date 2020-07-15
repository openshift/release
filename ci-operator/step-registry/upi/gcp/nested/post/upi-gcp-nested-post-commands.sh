#!/bin/bash

set -eo pipefail

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"

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
