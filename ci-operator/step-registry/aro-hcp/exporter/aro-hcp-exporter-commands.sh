#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable tracing to prevent credential exposure
set +o xtrace

echo "Pushing aro-hcp-exporter image to ACR..."

# Azure login using cluster profile credentials
export AZURE_CLIENT_ID
AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID
AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET
AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

echo "CI-built image: ${ARO_HCP_EXPORTER}"

export GOFLAGS='-mod=readonly'

# TODO: Remove after ARO-HCP oc_mirror branch merges to main
git remote add upstream https://github.com/Azure/ARO-HCP.git || true
git fetch upstream oc_mirror
git checkout upstream/oc_mirror -- tooling/aro-hcp-exporter/Makefile

# Resolve image variables from Makefile (uses templatize internally)
IMAGE_VARS_FILE="/tmp/image-vars.env"
make -C tooling/aro-hcp-exporter print-image-vars DEPLOY_ENV="${DEPLOY_ENV}" OUTPUT_FILE="${IMAGE_VARS_FILE}"
# shellcheck source=/dev/null
source "${IMAGE_VARS_FILE}"

echo "Resolved ACR: ${ARO_HCP_IMAGE_ACR}"
echo "Resolved image: ${ARO_HCP_EXPORTER_TAGGED_IMAGE}"

# Push to test repo instead of the resolved target
ACR_NAME="${ARO_HCP_IMAGE_ACR}"
ACR_REGISTRY="${ACR_NAME}.azurecr.io"
IMAGE_TAG="$(git rev-parse --short=7 HEAD)"
TARGET_IMAGE="${ACR_REGISTRY}/test-imani-aro-hcp-exporter:${IMAGE_TAG}"

echo "Target ACR image (test): ${TARGET_IMAGE}"

# Set writable runtime dir for registry auth
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"
mkdir -p "${HOME}/.docker"

# Authenticate to CI registry (source)
oc registry login

# Authenticate to ACR (destination) without Docker daemon
ACR_TOKEN=$(az acr login --name "${ACR_NAME}" --expose-token --output tsv --query accessToken)
oc registry login --registry "${ACR_REGISTRY}" --auth-basic="00000000-0000-0000-0000-000000000000:${ACR_TOKEN}"

oc image mirror "${ARO_HCP_EXPORTER}" "${TARGET_IMAGE}"
echo "Image pushed successfully to ${TARGET_IMAGE}"
