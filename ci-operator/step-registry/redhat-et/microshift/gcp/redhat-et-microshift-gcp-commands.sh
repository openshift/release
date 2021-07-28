#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="us-east1"
GOOGLE_COMPUTE_REGION="us-east1-a"
GOOGLE_COMPUTE_ZONE="openshift-gce-devel"

INSTANCE_PREFIX="microshift-release-ci-${NAMESPACE}-${JOB_NAME_HASH}"

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh

mock-nss.sh

# gcloud compute will use this key rather than create a new one
chmod 0600 "${HOME}"/.ssh/google_compute_engine
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud auth activate-service-account --quiet --key-file ""
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute instances create "$INSTANCE_PREFIX" --image-family=rhel-8 \
  --image-project=rhel-cloud \
  --zone=us-central1-a