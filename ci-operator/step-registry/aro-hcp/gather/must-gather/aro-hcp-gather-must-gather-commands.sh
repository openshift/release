#!/bin/bash
set -euo pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Skip if provisioning never completed — there are no cluster logs to gather.
if [[ ! -f "${SHARED_DIR}/provision-complete" && ! -f "${SHARED_DIR}/provision-from-main-complete" ]]; then
  echo "Provisioning did not complete, skipping must-gather"
  exit 0
fi

if [[ ! -f "${SHARED_DIR}/config.yaml" ]]; then
  echo "ERROR: config.yaml not found at ${SHARED_DIR}/config.yaml"
  exit 1
fi

KUSTO_NAME=$(yq '.kusto.kustoName' "${SHARED_DIR}/config.yaml")
KUSTO_REGION=$(yq '.kusto.location' "${SHARED_DIR}/config.yaml")

echo "KUSTO_NAME: ${KUSTO_NAME}"
echo "KUSTO_REGION: ${KUSTO_REGION}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"

MUST_GATHER_DIR="${ARTIFACT_DIR}/must-gather"
mkdir -p "${MUST_GATHER_DIR}"

# Scope the query to the last 3 hours to cover the CI job window and avoid
# hitting Kusto server limits. The default --limit -1 (unlimited) causes
# server-side errors; 2000 rows per query is sufficient for a CI run.
TIMESTAMP_MIN=$(date -u -d '3 hours ago' '+%Y-%m-%d %H:%M:%S')

# hcpctl must-gather is best-effort: partial data is better than no data.
if ! hcpctl must-gather query \
  --kusto "${KUSTO_NAME}" \
  --region "${KUSTO_REGION}" \
  --subscription-id "${INFRA_SUBSCRIPTION_ID}" \
  --timestamp-min "${TIMESTAMP_MIN}" \
  --limit 2000 \
  --output-path "${MUST_GATHER_DIR}"; then
  echo "WARNING: hcpctl must-gather query failed, compressing partial output"
fi

echo "must-gather complete, compressing artifacts"
tar -czf "${ARTIFACT_DIR}/must-gather.tar.gz" -C "${ARTIFACT_DIR}" must-gather/
echo "must-gather.tar.gz written to ${ARTIFACT_DIR}"
