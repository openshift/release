#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${JOB_NAME_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

# extract ccoctl from the release image
CCO_IMAGE=$(oc adm release info --image-for='cloud-credential-operator' "$RELEASE_IMAGE_LATEST")
cd "/tmp"
oc image extract "$CCO_IMAGE" --file="/usr/bin/ccoctl"
chmod 555 "/tmp/ccoctl"

# delete credentials infrastructure created by oidc-creds-provision configure step
"/tmp/ccoctl" aws delete --name="${infra_name}" --region="${REGION}"
