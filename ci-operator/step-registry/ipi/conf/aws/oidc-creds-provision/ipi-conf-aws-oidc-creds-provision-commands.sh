#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MPREFIX="${SHARED_DIR}/manifest"
TPREFIX="${SHARED_DIR}/tls"
infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

# extract ccoctl from the release image
cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
CCO_IMAGE=$(oc adm release info --image-for='cloud-credential-operator' "$RELEASE_IMAGE_LATEST" -a /tmp/pull-secret)
cd "/tmp"
oc image extract "$CCO_IMAGE" --file="/usr/bin/ccoctl" -a /tmp/pull-secret
chmod 555 "/tmp/ccoctl"

# extract aws credentials requests from the release image
oc adm release extract --credentials-requests --cloud=aws --to="/tmp/credrequests" "$RELEASE_IMAGE_LATEST" -a /tmp/pull-secret

# create required credentials infrastructure and installer manifests
"/tmp/ccoctl" aws create-all --name="${infra_name}" --region="${REGION}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp $FILE "${MPREFIX}_$FILE"; done
