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

# TODO: Remove after ARO-HCP oc_mirror branch merges to main
git remote add upstream https://github.com/Azure/ARO-HCP.git || true
git fetch upstream oc_mirror
git checkout upstream/oc_mirror -- tooling/aro-hcp-exporter/Makefile

# Use the Makefile acr-push target which resolves ACR coordinates
# via setup-templatize-env.mk and pushes using oc image mirror
make -C tooling/aro-hcp-exporter acr-push \
  DEPLOY_ENV="${DEPLOY_ENV}" \
  SOURCE_IMAGE="${ARO_HCP_EXPORTER}"
