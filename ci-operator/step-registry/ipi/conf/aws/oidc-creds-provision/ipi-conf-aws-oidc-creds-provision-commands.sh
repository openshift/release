#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

echo "> Extract aws credentials requests from the release image"
oc registry login
oc adm release extract --credentials-requests --cloud=aws --to="/tmp/credrequests" "$RELEASE_IMAGE_LATEST"

echo "> Generated the following CredentialsRequests"
ls /tmp/credrequests

echo "> Create required credentials infrastructure and installer manifests"
ccoctl aws create-all --name="${infra_name}" --region="${REGION}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

echo "> Copy generated service account signing from ccoctl target directory into shared directory"
cp -v "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

echo "> Copy generated secret manifests from ccoctl target directory into shared directory"
cd "/tmp/manifests"
for FILE in *; do cp -v $FILE "${MPREFIX}/$FILE"; done
