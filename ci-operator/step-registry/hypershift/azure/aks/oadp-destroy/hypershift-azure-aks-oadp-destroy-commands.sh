#!/bin/bash

set -euo pipefail

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"

if [ ! -f "${SHARED_DIR}/oadp-storage-account-name" ]; then
    echo "No oadp-storage-account-name file found, skipping storage account cleanup"
    exit 0
fi

STORAGE_ACCOUNT_NAME="$(cat "${SHARED_DIR}/oadp-storage-account-name")"
RESOURCEGROUP_AKS="$(cat "${SHARED_DIR}/resourcegroup_aks")"

echo "Reading Azure credentials..."
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

echo "Logging into Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

echo "Deleting storage account ${STORAGE_ACCOUNT_NAME}..."
RETRIES=3
for attempt in $(seq "${RETRIES}"); do
  if az storage account delete \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${RESOURCEGROUP_AKS}" \
    --yes; then
    echo "Storage account deleted successfully"
    break
  fi
  echo "Attempt ${attempt}/${RETRIES}: Failed to delete storage account. Retrying in 30 seconds..."
  sleep 30
  if [[ "${attempt}" -eq "${RETRIES}" ]]; then
    echo "Error: Failed to delete storage account after ${RETRIES} attempts"
    exit 1
  fi
done

echo "Storage account cleanup done"
