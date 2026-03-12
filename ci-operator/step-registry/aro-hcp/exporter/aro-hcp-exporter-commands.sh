#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable tracing to prevent credential exposure
set +o xtrace

echo "Pushing aro-hcp-exporter image to ACR..."

# Azure login using cluster profile credentials
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

# Resolve ACR target using templatize
cd tooling/aro-hcp-exporter
make -o ../../tooling/templatize/templatize /tmp/env.*.mk 2>/dev/null || true

# Source the generated env file to get ARO_HCP_IMAGE_ACR and image repo
ENV_FILE=$(find /tmp -maxdepth 1 -name 'env.*.mk' -print -quit)
if [[ -z "${ENV_FILE}" ]]; then
  echo "ERROR: templatize env file not found"
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

ACR_NAME="${ARO_HCP_IMAGE_ACR}"
ACR_REGISTRY="${ACR_NAME}.azurecr.io"
IMAGE_REPO="${ARO_HCP_EXPORTER_IMAGE_REPOSITORY}"
IMAGE_TAG="$(git rev-parse --short=7 HEAD)"

# Login to ACR
az acr login --name "${ACR_NAME}"

# The CI-built image is available via the ARO_HCP_EXPORTER env var
echo "Copying ${ARO_HCP_EXPORTER} to ${ACR_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
oc image mirror "${ARO_HCP_EXPORTER}" "${ACR_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

echo "Image pushed successfully to ${ACR_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
