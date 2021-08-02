#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export ALIBABA_CLOUD_CREDENTIALS_FILE=${SHARED_DIR}/alibabacreds.ini
cluster_id="${NAMESPACE}-${JOB_NAME_HASH}"

# extract ccoctl from the release image
CCO_IMAGE=$(oc adm release info --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}")
cd "/tmp"
oc image extract "${CCO_IMAGE}" --file="/usr/bin/ccoctl"
chmod 555 "/tmp/ccoctl"

# delete credentials infrastructure created by cloud-creds-provision configure step
"/tmp/ccoctl" alibabacloud \
  delete-ram-users \
  --name="${cluster_id}"
