#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${UNIQUE_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh
mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"


echo "scp crc logs back to pod"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
    --quiet \
    --project "${GOOGLE_PROJECT_ID}" \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    --recurse packer@"${INSTANCE_PREFIX}":~/.crc/crc.log ${ARTIFACT_DIR}

echo "scp test logs and build artifacts dir back to pod"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
    --quiet \
    --project "${GOOGLE_PROJECT_ID}" \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    --recurse packer@"${INSTANCE_PREFIX}":~/crc/out/ ${ARTIFACT_DIR} || true
