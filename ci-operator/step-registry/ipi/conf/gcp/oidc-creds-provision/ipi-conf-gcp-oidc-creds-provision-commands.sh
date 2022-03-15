#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

# extract gcp credentials requests from the release image
oc registry login
oc adm release extract --credentials-requests --cloud=gcp --to="/tmp/credrequests" "$RELEASE_IMAGE_LATEST"

# create required credentials infrastructure and installer manifests for workload identity
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
ccoctl gcp create-all --name="${infra_name}" --project="${PROJECT}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp $FILE "${MPREFIX}_$FILE"; done
