#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Tracing is disabled while the client-secret is read and used, otherwise xtrace
# expands it into the publicly readable build log.
set +o xtrace
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export GLOBAL_INFRA_SUBSCRIPTION_ID; GLOBAL_INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-global-subscription-id")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
set -o xtrace
az account set --subscription "${GLOBAL_INFRA_SUBSCRIPTION_ID}"

MUST_GATHER_DIR="${ARTIFACT_DIR}/must-gather"
mkdir -p "${MUST_GATHER_DIR}"

# Any data is useful even if some resource groups fail to gather.
set +o errexit
export AZURE_TOKEN_CREDENTIALS=prod
test/aro-hcp-tests gather-must-gather \
  --timing-input "${SHARED_DIR}" \
  --rendered-config "${SHARED_DIR}/config.yaml" \
  --output "${MUST_GATHER_DIR}"

echo "must-gather complete, compressing artifacts"
tar -czf "${ARTIFACT_DIR}/must-gather.tar.gz" -C "${ARTIFACT_DIR}" must-gather/ || true
echo "must-gather.tar.gz written to ${ARTIFACT_DIR}"
