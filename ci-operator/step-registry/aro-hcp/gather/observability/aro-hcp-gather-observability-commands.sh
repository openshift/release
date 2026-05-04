#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"


START_TIME_FALLBACK_ARGS=""
if [[ -f "${SHARED_DIR}/write-config-timestamp-rfc3339" ]]; then
  START_TIME_FALLBACK_ARGS="--start-time-fallback $(cat "${SHARED_DIR}/write-config-timestamp-rfc3339")"
fi

export AZURE_TOKEN_CREDENTIALS=prod
test/aro-hcp-tests gather-observability \
  --timing-input "${SHARED_DIR}" \
  --output "${ARTIFACT_DIR}/" \
  --rendered-config "${SHARED_DIR}/config.yaml" \
  --subscription-id "${INFRA_SUBSCRIPTION_ID}" \
  --severity-threshold Sev3 \
  ${START_TIME_FALLBACK_ARGS}
