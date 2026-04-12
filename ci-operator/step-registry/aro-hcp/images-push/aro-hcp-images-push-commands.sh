#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set +o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Azure login
export AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET
AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

export GOFLAGS='-mod=readonly'

# TODO: Remove after ARO-HCP vars_for_prow_job branch merges to main
git remote add upstream https://github.com/Azure/ARO-HCP.git || true
git fetch upstream vars_for_prow_job
git checkout upstream/vars_for_prow_job -- \
  backend/Makefile frontend/Makefile admin/Makefile \
  sessiongate/Makefile image-sync/oc-mirror/Makefile \
  tooling/aro-hcp-exporter/Makefile

# Authenticate to CI registry
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers" "${HOME}/.docker"
oc registry login

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

# Resolve vars, authenticate to ACR, and push a single image to a temp repo
# Pass "latest" as 4th arg to also push a :latest tag
push_image() {
  local makefile_dir=$1
  local src_image=$2
  local image_name=$3
  local push_latest=${4:-}

  make -C "${makefile_dir}" export-image-vars DEPLOY_ENV="${DEPLOY_ENV}" IMAGE_VARS_FILE="/tmp/image-vars.env"
  # shellcheck source=/dev/null
  source "/tmp/image-vars.env"

  ACR_TOKEN=$(az acr login --name "${IMAGE_REGISTRY}" --expose-token --output tsv --query accessToken)
  oc registry login --registry "${IMAGE_REGISTRY}" --auth-basic="00000000-0000-0000-0000-000000000000:${ACR_TOKEN}"

  local target="${IMAGE_REGISTRY}/test-${image_name}:${IMAGE_TAG}"
  echo "Pushing ${src_image} -> ${target}"
  retry oc image mirror "${src_image}" "${target}"

  if [[ "${push_latest}" == "latest" ]]; then
    local target_latest="${IMAGE_REGISTRY}/test-${image_name}:latest"
    echo "Pushing ${src_image} -> ${target_latest}"
    retry oc image mirror "${src_image}" "${target_latest}"
  fi
}

push_image backend              "${ARO_HCP_BACKEND}"     aro-hcp-backend
push_image frontend             "${ARO_HCP_FRONTEND}"    aro-hcp-frontend
push_image admin                "${ARO_HCP_ADMIN_API}"   aro-hcp-admin-api
push_image sessiongate          "${ARO_HCP_SESSIONGATE}" aro-hcp-sessiongate
push_image image-sync/oc-mirror       "${ARO_HCP_OC_MIRROR}"   aro-hcp-oc-mirror latest
push_image tooling/aro-hcp-exporter   "${ARO_HCP_EXPORTER}"    aro-hcp-exporter

echo "All images pushed successfully."
