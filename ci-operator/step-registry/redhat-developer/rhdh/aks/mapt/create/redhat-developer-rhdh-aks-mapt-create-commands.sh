#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  # Temporarily disable exit on error to capture failures
  set +o errexit

  export PULUMI_K8S_DELETE_UNREACHABLE=true
  echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

  echo "[INFO] 🗑️ Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

  # Capture both stdout and stderr to check for errors
  output=$(mapt azure aks destroy \
    --project-name "aks" \
    --backed-url "azblob://${AZURE_STORAGE_BLOB}/${CORRELATE_MAPT}" 2>&1)
  exit_code=$?

  # Re-enable exit on error
  set -o errexit

  # Check for both exit code and error patterns in output
  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
    echo "$output"
    echo "[SUCCESS] ✅ Successfully destroyed MAPT: ${CORRELATE_MAPT}"

    echo "[INFO] 🗑️ Deleting folder ${CORRELATE_MAPT}/ from Azure Blob Storage..."
    az storage blob delete-batch \
      --source "${AZURE_STORAGE_BLOB}" \
      --account-name "${AZURE_STORAGE_ACCOUNT}" \
      --account-key "${AZURE_STORAGE_KEY}" \
      --pattern "${CORRELATE_MAPT}/*"

    echo "[SUCCESS] ✅ Successfully deleted folder ${CORRELATE_MAPT} from blob container"
  else
    echo "$output"
    echo "[ERROR] ❌ Failed to destroy MAPT: ${CORRELATE_MAPT}"
    echo "[WARN] ⚠️ Skipping deletion of folder ${CORRELATE_MAPT} from Azure Blob Storage due to destroy failure"
    exit 1
  fi
}

echo "[INFO] 🔐 Loading Azure credentials from secrets..."
AZURE_STORAGE_ACCOUNT=$(cat /tmp/secrets/AZURE_STORAGE_ACCOUNT)
AZURE_STORAGE_BLOB=$(cat /tmp/secrets/AZURE_STORAGE_BLOB)
AZURE_STORAGE_KEY=$(cat /tmp/secrets/AZURE_STORAGE_KEY)
ARM_CLIENT_ID=$(cat /tmp/secrets/ARM_CLIENT_ID)
ARM_CLIENT_SECRET=$(cat /tmp/secrets/ARM_CLIENT_SECRET)
ARM_SUBSCRIPTION_ID=$(cat /tmp/secrets/ARM_SUBSCRIPTION_ID)
ARM_TENANT_ID=$(cat /tmp/secrets/ARM_TENANT_ID)
export AZURE_STORAGE_ACCOUNT AZURE_STORAGE_BLOB AZURE_STORAGE_KEY ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID
echo "[SUCCESS] ✅ Azure credentials loaded successfully"

echo "[INFO] 🏷️ Setting CORRELATE_MAPT..."
CORRELATE_MAPT="aks-${BUILD_ID}"
export CORRELATE_MAPT

# Trap TERM signal (job was interrupted/cancelled) into cleanup function
trap cleanup TERM

echo "[INFO] 🚀 Creating MAPT infrastructure for ${CORRELATE_MAPT}..."
mapt azure aks create \
  --project-name "aks" \
  --backed-url "azblob://${AZURE_STORAGE_BLOB}/${CORRELATE_MAPT}" \
  --conn-details-output "${SHARED_DIR}" \
  --version 1.33 \
  --vmsize "Standard_D4as_v6" \
  --spot \
  --spot-eviction-tolerance "low" \
  --spot-excluded-regions "centralindia" \
  --enable-app-routing && \
echo "[SUCCESS] ✅ MAPT AKS cluster created successfully"
