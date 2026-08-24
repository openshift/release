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
PRIVATE_KEY_PATH="${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${PRIVATE_KEY_PATH}"
chmod 0600 "${PRIVATE_KEY_PATH}"
lastchar=$(tail -c1 "${PRIVATE_KEY_PATH}")
if [ -n "$lastchar" ]; then
    echo >> "${PRIVATE_KEY_PATH}"
fi
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

BUCKET="gs://crc-bundle-${PULL_NUMBER}"
echo "Check if ${BUCKET} bucket exists"
if LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud storage buckets describe "${BUCKET}" \
    --quiet \
    --project="${GOOGLE_PROJECT_ID}" >/dev/null 2>&1; then
  echo "Bucket '${BUCKET}' already exists. No action needed."
else
  echo "create crc-bundle-${PULL_NUMBER} bucket"
  if ! LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud storage buckets create "${BUCKET}" \
      --quiet \
      --project="${GOOGLE_PROJECT_ID}"; then
    # Bucket may already exist (e.g. created by a parallel job) even if describe failed.
    if LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud storage buckets describe "${BUCKET}" \
        --quiet \
        --project="${GOOGLE_PROJECT_ID}" >/dev/null 2>&1; then
      echo "Bucket '${BUCKET}' already exists. No action needed."
    else
      echo "Failed to create bucket '${BUCKET}'"
      exit 1
    fi
  fi
fi

echo "Upload the bundle to gcp crc-bundle bucket"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gsutil cp /tmp/*.crcbundle gs://crc-bundle-"${PULL_NUMBER}"/

echo "Make Bundle publicly accessible from bucket"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gsutil acl \
   ch -r -u AllUsers:R gs://crc-bundle-"${PULL_NUMBER}"/

echo "Create file in artifact directory, having links to storage links"
find /tmp/ -maxdepth 1 -name "*.crcbundle" -printf "https://storage.googleapis.com/crc-bundle-${PULL_NUMBER}/%f\n" > ${ARTIFACT_DIR}/bundles.txt
