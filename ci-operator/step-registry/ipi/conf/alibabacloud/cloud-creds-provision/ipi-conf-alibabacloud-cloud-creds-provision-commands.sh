#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CR_PATH="/tmp/credrequests"
MPREFIX="${SHARED_DIR}/manifest"
cluster_id="${NAMESPACE}-${UNIQUE_HASH}"
export ALIBABA_CLOUD_CREDENTIALS_FILE="${SHARED_DIR}/alibabacreds.ini"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

# extract ccoctl from the release image
oc registry login
# extract alibabacloud credentials requests from the release image
oc --loglevel 10 adm release extract --credentials-requests --cloud=alibabacloud --to="${CR_PATH}" "${RELEASE_IMAGE_LATEST}"

# create required credentials infrastructure and installer manifests for workload identity
ccoctl alibabacloud create-ram-users \
    --region "${LEASED_RESOURCE}" \
    --name="${cluster_id}" \
    --credentials-requests-dir="${CR_PATH}" \
    --output-dir="/tmp"

cd "/tmp/manifests"
# copy generated secret manifests from ccoctl target directory into shared directory
for FILE in *; do cp "${FILE}" "${MPREFIX}_${FILE}"; done
