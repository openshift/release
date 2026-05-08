#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Guard: only run if the subcommand exists in this build of the binary
if ! test/aro-hcp-tests gather-snapshot --help &>/dev/null; then
  echo "gather-snapshot subcommand not available in this binary, skipping."
  exit 0
fi

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export GLOBAL_INFRA_SUBSCRIPTION_ID; GLOBAL_INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-global-subscription-id")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${GLOBAL_INFRA_SUBSCRIPTION_ID}"

export AZURE_TOKEN_CREDENTIALS=prod
test/aro-hcp-tests gather-snapshot \
  --timing-input "${SHARED_DIR}" \
  --output "${ARTIFACT_DIR}/" \
  --rendered-config "${SHARED_DIR}/config.yaml"
