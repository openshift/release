#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"

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

echo "scp installer logs back to pod"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
    --quiet \
    --project "${GOOGLE_PROJECT_ID}" \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    --recurse packer@"${INSTANCE_PREFIX}":~/snc/crc-tmp-install-data ${ARTIFACT_DIR}

echo "scp bundles back to pod tmp directory"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
    --quiet \
    --project "${GOOGLE_PROJECT_ID}" \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    --recurse packer@"${INSTANCE_PREFIX}":~/snc/*.crcbundle /tmp

echo "Upload the bundle to gcp crc-bundle bucket"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gsutil cp /tmp/*.crcbundle gs://crc-bundle/

echo "Make Bundle publicly accessible from bucket"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gsutil acl \
   ch -r -u AllUsers:R gs://crc-bundle/

echo "Create file in artifact directory, having links to storage links"
find /tmp/ -maxdepth 1 -name "*.crcbundle" -exec basename \"{}\" \; | awk '{print "https://storage.googleapis.com/crc-bundle/" $0 ""}' > ${ARTIFACT_DIR}/bundles.txt
