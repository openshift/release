#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${UNIQUE_HASH}
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

echo "> Extract gcp credentials requests from the release image"
oc registry login
oc adm release extract --credentials-requests --cloud=gcp --to="/tmp/credrequests" "$RELEASE_IMAGE_LATEST"

echo "> Output gcp credentials requests to directory: /tmp/credrequests"
ls "/tmp/credrequests"

echo "> Create required credentials infrastructure and installer manifests for workload identity"
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
ccoctl gcp create-all --name="${infra_name}" --project="${PROJECT}" --region="${LEASED_RESOURCE}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

echo "> Copy generated service account signing from ccoctl target directory into shared directory"
cp -v "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

echo "> Copy generated secret manifests from ccoctl target directory into shared directory"
cd "/tmp/manifests"
for FILE in *; do cp -v $FILE "${MPREFIX}_$FILE"; done
