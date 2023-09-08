#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/nutanix_context.sh"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

CR_DIR="/tmp/credentials_request"
mkdir -p "${CR_DIR}"

MANIFEST_PREFIX="${SHARED_DIR}/manifest"

# Create the Nutanix credentials secret
cat > ${SHARED_DIR}/credentials <<EOF
credentials:
- type: basic_auth
  data:
    prismCentral:
      username: ${NUTANIX_USERNAME}
      password: ${NUTANIX_PASSWORD}
    prismElements: null
EOF

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

# Extract credential requests
oc registry login
ADDITIONAL_OC_EXTRACT_ARGS=""
if [[ "${EXTRACT_MANIFEST_INCLUDED}" == "true" ]]; then
  ADDITIONAL_OC_EXTRACT_ARGS="${ADDITIONAL_OC_EXTRACT_ARGS} --included --install-config=${SHARED_DIR}/install-config.yaml"
fi
echo "OC Version:"
which oc
oc version --client
oc adm release extract --help
oc adm release extract --credentials-requests --cloud=nutanix --to "${CR_DIR}" ${ADDITIONAL_OC_EXTRACT_ARGS} "${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"

echo "Extracted credentials requests:"
ls -l "${CR_DIR}"

ADDITIONAL_CCOCTL_ARGS=""
if [[ "${FEATURE_SET}" == "TechPreviewNoUpgrade" ]]; then
  ADDITIONAL_CCOCTL_ARGS="$ADDITIONAL_CCOCTL_ARGS --enable-tech-preview"
fi

# Create the credentials request manifest
ccoctl nutanix create-shared-secrets \
      --credentials-requests-dir="${CR_DIR}" \
      --output-dir="/tmp" \
      --credentials-source-filepath="${SHARED_DIR}/credentials" \
      ${ADDITIONAL_CCOCTL_ARGS}

echo "Created credentials request manifest:"
ls -l "/tmp/manifests"

# Copy the manifest to the shared directory
pushd "/tmp/manifests"
for FILE in *.yaml; do
  echo "Copying ${FILE} to ${MANIFEST_PREFIX}"
  cp "${FILE}" "${MANIFEST_PREFIX}_${FILE}"
done
popd
