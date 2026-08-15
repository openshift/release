#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set +o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

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

CONFIG_FILE="config/config-dev-ci.yaml"
ACR_NAME=$(yq '.clouds.dev.defaults.svc.acr.name' "${CONFIG_FILE}")
ACR_URL="${ACR_NAME}.azurecr.io"
TENANT_QUOTA_REPO=$(yq '.clouds.dev.defaults.opstool.tenantQuota.image.repository' "${CONFIG_FILE}")

echo "Target ACR: ${ACR_URL}"
echo "Repos: tenant-quota=${TENANT_QUOTA_REPO}"

export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers" "${HOME}/.docker"
oc registry login

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

echo "Pushing tenant-quota: ${ARO_HCP_TENANT_QUOTA} -> ${ACR_URL}/${TENANT_QUOTA_REPO}:${IMAGE_TAG}"
retry oc image mirror "${ARO_HCP_TENANT_QUOTA}" "${ACR_URL}/${TENANT_QUOTA_REPO}:${IMAGE_TAG}"

echo "Pushing tenant-quota latest: ${ARO_HCP_TENANT_QUOTA} -> ${ACR_URL}/${TENANT_QUOTA_REPO}:latest"
retry oc image mirror "${ARO_HCP_TENANT_QUOTA}" "${ACR_URL}/${TENANT_QUOTA_REPO}:latest"

echo "All CI images pushed successfully."
