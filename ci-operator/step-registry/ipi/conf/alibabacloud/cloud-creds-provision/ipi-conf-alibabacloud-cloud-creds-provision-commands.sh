#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CR_PATH="/tmp/credrequests"
MPREFIX="${SHARED_DIR}/manifest"
cluster_id="${NAMESPACE}-${JOB_NAME_HASH}"
export ALIBABA_CLOUD_CREDENTIALS_FILE="${SHARED_DIR}/alibabacreds.ini"

# extract ccoctl from the release image
oc registry login
CCO_IMAGE=$(oc adm release info --image-for='cloud-credential-operator' "${RELEASE_IMAGE_LATEST}")
cd "/tmp"
oc --loglevel 10 image extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${CCO_IMAGE}" --file="/usr/bin/ccoctl"
chmod 555 "/tmp/ccoctl"

# extract alibabacloud credentials requests from the release image
oc --loglevel 10 adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --credentials-requests --cloud=alibabacloud --to="${CR_PATH}" "${RELEASE_IMAGE_LATEST}"

# create required credentials infrastructure and installer manifests for workload identity
"/tmp/ccoctl" alibabacloud create-ram-users \
    --region "${LEASED_RESOURCE}" \
    --name="${cluster_id}" \
    --credentials-requests-dir="${CR_PATH}" \
    --output-dir="/tmp"

cd "/tmp/manifests"
# copy generated secret manifests from ccoctl target directory into shared directory
for FILE in *; do cp "${FILE}" "${MPREFIX}_${FILE}"; done
