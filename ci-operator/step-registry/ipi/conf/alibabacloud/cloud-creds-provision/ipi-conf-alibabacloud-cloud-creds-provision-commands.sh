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

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

# extract ccoctl from the release image
oc registry login
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help
# extract alibabacloud credentials requests from the release image
oc --loglevel 10 adm release extract --credentials-requests --cloud=alibabacloud --to="${CR_PATH}" ${ADDITIONAL_OC_EXTRACT_ARGS} "${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
echo "CR manifest files:"
ls "${CR_PATH}"

ADDITIONAL_CCOCTL_ARGS=""
if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
  ADDITIONAL_CCOCTL_ARGS="$ADDITIONAL_CCOCTL_ARGS --enable-tech-preview"
fi

# create required credentials infrastructure and installer manifests for workload identity
ccoctl alibabacloud create-ram-users \
    --region "${LEASED_RESOURCE}" \
    --name="${cluster_id}" \
    --credentials-requests-dir="${CR_PATH}" \
    --output-dir="/tmp" \
    ${ADDITIONAL_CCOCTL_ARGS}

cd "/tmp/manifests"
# copy generated secret manifests from ccoctl target directory into shared directory
for FILE in *; do cp "${FILE}" "${MPREFIX}_${FILE}"; done
