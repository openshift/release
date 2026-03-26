#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable tracing to prevent credential exposure
set +o xtrace

echo "Pushing aro-hcp-backend image to ACR..."

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

echo "CI-built image: ${ARO_HCP_BACKEND}"

export GOFLAGS='-mod=readonly'

# TODO: Remove after ARO-HCP vars_for_prow_job branch merges to main
git remote add upstream https://github.com/Azure/ARO-HCP.git || true
git fetch upstream vars_for_prow_job
git checkout upstream/vars_for_prow_job -- backend/Makefile

# Resolve image variables from Makefile (uses templatize internally)
IMAGE_VARS_FILE="/tmp/image-vars.env"
make -C backend export-image-vars DEPLOY_ENV="${DEPLOY_ENV}" IMAGE_VARS_FILE="${IMAGE_VARS_FILE}"
# shellcheck source=/dev/null
source "${IMAGE_VARS_FILE}"

echo "Resolved ACR: ${IMAGE_REGISTRY}"
echo "Resolved image: ${IMAGE_REF}"

# Push to test repo instead of the resolved target
IMAGE_TAG="$(git rev-parse --short=7 HEAD)"
TARGET_IMAGE="${IMAGE_REGISTRY}/test-imani-aro-hcp-backend:${IMAGE_TAG}"

echo "Target ACR image (test): ${TARGET_IMAGE}"

# Set writable runtime dir for registry auth
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"
mkdir -p "${HOME}/.docker"

# Authenticate to CI registry (source)
oc registry login

# Authenticate to ACR (destination) without Docker daemon
ACR_TOKEN=$(az acr login --name "${IMAGE_REGISTRY}" --expose-token --output tsv --query accessToken)
oc registry login --registry "${IMAGE_REGISTRY}" --auth-basic="00000000-0000-0000-0000-000000000000:${ACR_TOKEN}"

oc image mirror "${ARO_HCP_BACKEND}" "${TARGET_IMAGE}"
echo "Image pushed successfully to ${TARGET_IMAGE}"
