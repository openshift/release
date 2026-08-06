#!/bin/bash

set -euo pipefail

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"

STORAGE_ACCOUNT_MARKER="${SHARED_DIR}/oadp-storage-account-name"
STORAGE_RESOURCEGROUP_MARKER="${SHARED_DIR}/oadp-storage-resourcegroup"
OADP_MI_MARKER="${SHARED_DIR}/oadp-workload-identity-name"
OADP_MI_RG_MARKER="${SHARED_DIR}/oadp-workload-identity-resourcegroup"

if [[ ! -f "${STORAGE_ACCOUNT_MARKER}" && ! -f "${OADP_MI_MARKER}" ]]; then
  echo "No OADP storage account or workload identity marker files found, nothing to clean up"
  exit 0
fi

echo "Reading Azure credentials..."
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

echo "Logging into Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

OVERALL_RESULT=0

# --- Storage account cleanup (Velero) ---
if [[ -f "${STORAGE_ACCOUNT_MARKER}" ]]; then
  STORAGE_ACCOUNT_NAME="$(cat "${STORAGE_ACCOUNT_MARKER}")"
  if [[ ! -f "${STORAGE_RESOURCEGROUP_MARKER}" ]]; then
    echo "Error: ${STORAGE_RESOURCEGROUP_MARKER} missing, cannot delete storage account ${STORAGE_ACCOUNT_NAME}"
    OVERALL_RESULT=1
  else
    RESOURCEGROUP="$(cat "${STORAGE_RESOURCEGROUP_MARKER}")"

    echo "Deleting storage account ${STORAGE_ACCOUNT_NAME}..."
    RETRIES=3
    STORAGE_DELETED=false
    for attempt in $(seq "${RETRIES}"); do
      if az storage account delete \
        --name "${STORAGE_ACCOUNT_NAME}" \
        --resource-group "${RESOURCEGROUP}" \
        --yes; then
        echo "Storage account deleted successfully"
        STORAGE_DELETED=true
        break
      fi
      echo "Attempt ${attempt}/${RETRIES}: Failed to delete storage account. Retrying in 30s..."
      sleep 30
    done
    if [[ "${STORAGE_DELETED}" != "true" ]]; then
      echo "Error: Failed to delete storage account ${STORAGE_ACCOUNT_NAME} after ${RETRIES} attempts"
      OVERALL_RESULT=1
    fi
  fi
else
  echo "No oadp-storage-account-name file found, skipping storage account cleanup"
fi

# --- OADP workload identity cleanup (Velero + etcd-backup) ---
# Deleting the managed identity also deletes any federated identity
# credentials attached to it; no separate
# `az identity federated-credential delete` call is required.
if [[ -f "${OADP_MI_MARKER}" ]]; then
  OADP_MI_NAME="$(cat "${OADP_MI_MARKER}")"
  OADP_MI_RESOURCEGROUP="$(cat "${OADP_MI_RG_MARKER}")"

  echo "Deleting managed identity ${OADP_MI_NAME}..."
  RETRIES=3
  MI_DELETED=false
  for attempt in $(seq "${RETRIES}"); do
    if az identity delete \
      --name "${OADP_MI_NAME}" \
      --resource-group "${OADP_MI_RESOURCEGROUP}"; then
      echo "Managed identity deleted successfully"
      MI_DELETED=true
      break
    fi
    echo "Attempt ${attempt}/${RETRIES}: Failed to delete managed identity. Retrying in 30s..."
    sleep 30
  done
  if [[ "${MI_DELETED}" != "true" ]]; then
    echo "Error: Failed to delete managed identity ${OADP_MI_NAME} after ${RETRIES} attempts"
    OVERALL_RESULT=1
  fi
else
  echo "No oadp-workload-identity-name file found, skipping OADP workload identity cleanup"
fi

echo "OADP resource cleanup done"
exit "${OVERALL_RESULT}"
