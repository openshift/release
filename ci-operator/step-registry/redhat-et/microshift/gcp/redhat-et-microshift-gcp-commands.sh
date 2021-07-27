#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "`id`"

GOOGLE_PROJECT_ID="us-east1"
GOOGLE_COMPUTE_REGION="us-east1-a"
GOOGLE_COMPUTE_ZONE="openshift-gce-devel"

INSTANCE_PREFIX="microshift-release-ci-${NAMESPACE}-${JOB_NAME_HASH}"

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh
mock-nss.sh

# gcloud compute will use this key rather than create a new one
mock-nss.sh chmod 0600 "${HOME}"/.ssh/google_compute_engine
mock-nss.sh echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
mock-nss.sh echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
mock-nss.sh chmod 0600 "${HOME}"/.ssh/config

mock-nss.sh gcloud auth activate-service-account --quiet --key-file ""
mock-nss.sh gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
mock-nss.sh gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
mock-nss.sh gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute instances create "$INSTANCE_PREFIX" --image-family=rhel-8 \
  --image-project=rhel-cloud \
  --zone=us-central1-a