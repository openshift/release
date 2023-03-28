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

# Extract credential requests
oc registry login
oc adm release extract --credentials-requests --cloud=nutanix --to "${CR_DIR}" "${RELEASE_IMAGE_LATEST}"

echo "Extracted credentials requests:"
ls -l "${CR_DIR}"

# Create the credentials request manifest
ccoctl nutanix create-shared-secrets \
      --credentials-requests-dir="${CR_DIR}" \
      --output-dir="/tmp" \
      --credentials-source-filepath="${SHARED_DIR}/credentials"

echo "Created credentials request manifest:"
ls -l "/tmp/manifests"

# Copy the manifest to the shared directory
pushd "/tmp/manifests"
for FILE in *.yaml; do
  echo "Copying ${FILE} to ${MANIFEST_PREFIX}"
  cp "${FILE}" "${MANIFEST_PREFIX}_${FILE}"
done
popd
