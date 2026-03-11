#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable tracing to prevent credential exposure
set +o xtrace

cd tooling/aro-hcp-exporter

# Always build the image
echo "Building aro-hcp-exporter image..."
make image

# Push only on postsubmit (merge to main)
if [[ "${JOB_TYPE}" == "postsubmit" ]]; then
  echo "Postsubmit detected, pushing image to ACR..."

  export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
  export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
  export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

  az login --service-principal \
    -u "${AZURE_CLIENT_ID}" \
    -p "${AZURE_CLIENT_SECRET}" \
    --tenant "${AZURE_TENANT_ID}" \
    --output none

  make build-and-push
  echo "Image pushed successfully."
else
  echo "Presubmit detected, skipping push."
fi
