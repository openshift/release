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
oc adm release extract --credentials-requests --cloud=aws --to="/tmp/credrequests" "$RELEASE_IMAGE_LATEST"


CCOCTL_OPTIONS=""

if [[ "${STS_USE_PRIVATE_S3}" == "yes" ]]; then
  CCOCTL_OPTIONS=" $CCOCTL_OPTIONS --create-private-s3-bucket "
fi

# create required credentials infrastructure and installer manifests
ccoctl aws create-all ${CCOCTL_OPTIONS} --name="${infra_name}" --region="${REGION}" --credentials-requests-dir="/tmp/credrequests" --output-dir="/tmp"

# copy generated service account signing from ccoctl target directory into shared directory
cp "/tmp/tls/bound-service-account-signing-key.key" "${TPREFIX}_bound-service-account-signing-key.key"

echo "Cluster authentication:"
cat "/tmp/manifests/cluster-authentication-02-config.yaml"
echo -e "\n"

# copy generated secret manifests from ccoctl target directory into shared directory
cd "/tmp/manifests"
for FILE in *; do cp $FILE "${MPREFIX}_$FILE"; done
