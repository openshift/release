#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

# extract aws credentials requests from the release image
oc registry login
# shellcheck disable=SC2153
REPO=$(oc -n ${NAMESPACE} get is release -o json | jq -r '.status.publicDockerImageRepository')
oc adm release extract --credentials-requests --cloud=aws --to="/tmp/credrequests" "${REPO}:latest"

# create required credentials infrastructure and installer manifests
ccoctl aws create-all --name="${infra_name}" --region="${REGION}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp $FILE "${MPREFIX}_$FILE"; done
