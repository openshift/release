#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set +o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Azure login
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

# Resolve ACR and repository names from rendered config
CONFIG_FILE="config/rendered/dev/${DEPLOY_ENV}/westus3.yaml"
ACR_NAME=$(yq '.acr.svc.name' "${CONFIG_FILE}")
ACR_URL="${ACR_NAME}.azurecr.io"
BACKEND_REPO=$(yq '.backend.image.repository' "${CONFIG_FILE}")
FRONTEND_REPO=$(yq '.frontend.image.repository' "${CONFIG_FILE}")
ADMIN_API_REPO=$(yq '.adminApi.image.repository' "${CONFIG_FILE}")
SESSIONGATE_REPO=$(yq '.sessiongate.image.repository' "${CONFIG_FILE}")
EXPORTER_REPO=$(yq '.customExporter.image.repository' "${CONFIG_FILE}")
OC_MIRROR_REPO=$(yq '.imageSync.ocMirror.image.repository' "${CONFIG_FILE}")
echo "Target ACR: ${ACR_URL}"
echo "Repos: backend=${BACKEND_REPO}, frontend=${FRONTEND_REPO}, admin-api=${ADMIN_API_REPO}, sessiongate=${SESSIONGATE_REPO}, exporter=${EXPORTER_REPO}, oc-mirror=${OC_MIRROR_REPO}"

# Authenticate to CI registry
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers" "${HOME}/.docker"
oc registry login

# Authenticate to ACR
ACR_TOKEN=$(az acr login --name "${ACR_NAME}" --expose-token --output tsv --query accessToken)
oc registry login --registry "${ACR_URL}" --auth-basic="00000000-0000-0000-0000-000000000000:${ACR_TOKEN}"

IMAGE_TAG="$(git rev-parse --short=7 HEAD)"

retry() {
  local attempt
  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    fi
    echo "Attempt ${attempt}/3 failed, retrying in 10s..."
    sleep 10
  done
  echo "Command failed after 3 attempts: $*"
  return 1
}

# Push service images
echo "Pushing backend: ${ARO_HCP_BACKEND} -> ${ACR_URL}/test-${BACKEND_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_BACKEND}" "${ACR_URL}/test-${BACKEND_REPO}:${IMAGE_TAG}"

echo "Pushing frontend: ${ARO_HCP_FRONTEND} -> ${ACR_URL}/test-${FRONTEND_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_FRONTEND}" "${ACR_URL}/test-${FRONTEND_REPO}:${IMAGE_TAG}"

echo "Pushing admin-api: ${ARO_HCP_ADMIN_API} -> ${ACR_URL}/test-${ADMIN_API_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_ADMIN_API}" "${ACR_URL}/test-${ADMIN_API_REPO}:${IMAGE_TAG}"

echo "Pushing sessiongate: ${ARO_HCP_SESSIONGATE} -> ${ACR_URL}/test-${SESSIONGATE_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_SESSIONGATE}" "${ACR_URL}/test-${SESSIONGATE_REPO}:${IMAGE_TAG}"

# Push non-pipeline images
echo "Pushing exporter: ${ARO_HCP_EXPORTER} -> ${ACR_URL}/test-${EXPORTER_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_EXPORTER}" "${ACR_URL}/test-${EXPORTER_REPO}:${IMAGE_TAG}"

echo "Pushing oc-mirror: ${ARO_HCP_OC_MIRROR} -> ${ACR_URL}/test-${OC_MIRROR_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_OC_MIRROR}" "${ACR_URL}/test-${OC_MIRROR_REPO}:${IMAGE_TAG}"

echo "Pushing oc-mirror latest: ${ARO_HCP_OC_MIRROR} -> ${ACR_URL}/test-${OC_MIRROR_REPO}:latest"
retry oc image mirror "${ARO_HCP_OC_MIRROR}" "${ACR_URL}/test-${OC_MIRROR_REPO}:latest"

echo "All images pushed successfully."
