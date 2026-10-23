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

# Bucket names are globally unique across all GCP projects, so derive the
# name from the project ID to avoid collisions with buckets owned by other
# projects. The project ID is a secret (it would be censored in logs and
# artifacts), so use a hash of it rather than the ID itself.
# A single shared bucket is used, with one prefix per PR, so the lifecycle
# rule below cleans everything up without leaving empty buckets behind.
PROJECT_HASH="$(echo -n "${GOOGLE_PROJECT_ID}" | sha256sum | cut -c1-16)"
BUCKET_NAME="crc-bundle-${PROJECT_HASH}"
BUCKET="gs://${BUCKET_NAME}"
BUNDLE_PATH="${BUCKET_NAME}/${PULL_NUMBER}"
echo "Check if ${BUCKET} bucket exists"
if LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud storage buckets describe "${BUCKET}" \
    --quiet \
    --project="${GOOGLE_PROJECT_ID}" >/dev/null 2>&1; then
  echo "Bucket '${BUCKET}' already exists. No action needed."
else
  echo "create ${BUCKET_NAME} bucket"
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

# Delete the bundles 10 days after upload.
echo "Set lifecycle rule on ${BUCKET} to delete objects after 10 days"
LIFECYCLE_FILE="$(mktemp)"
cat > "${LIFECYCLE_FILE}" <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 10}
    }
  ]
}
EOF
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud storage buckets update "${BUCKET}" \
    --quiet \
    --project="${GOOGLE_PROJECT_ID}" \
    --lifecycle-file="${LIFECYCLE_FILE}"
rm -f "${LIFECYCLE_FILE}"

echo "Upload the bundle to gcp crc-bundle bucket"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gsutil cp /tmp/*.crcbundle gs://"${BUNDLE_PATH}"/

echo "Make Bundle publicly accessible from bucket"
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gsutil acl \
   ch -r -u AllUsers:R gs://"${BUNDLE_PATH}"/

echo "Create file in artifact directory, having links to storage links"
find /tmp/ -maxdepth 1 -name "*.crcbundle" -printf "https://storage.googleapis.com/${BUNDLE_PATH}/%f\n" > ${ARTIFACT_DIR}/bundles.txt
