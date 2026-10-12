#!/bin/bash

set -e

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

echo "[INFO] 🔐 Authenticating to Azure..."
az login --service-principal \
  --username "${ARM_CLIENT_ID}" \
  --password "${ARM_CLIENT_SECRET}" \
  --tenant "${ARM_TENANT_ID}"
az account set --subscription "${ARM_SUBSCRIPTION_ID}"

echo "[INFO] 📋 Listing blobs from container ${AZURE_STORAGE_BLOB}..."
az storage blob list \
  --container-name "${AZURE_STORAGE_BLOB}" \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --account-key "${AZURE_STORAGE_KEY}" \
  --output json  | \
  jq -r '.[].name | split("/")[0] | select(length > 0)' | \
  sort -u > "${SHARED_DIR}/blob_top_level_folders.txt"

if [ -f "${SHARED_DIR}/blob_top_level_folders.txt" ]; then
  echo "[SUCCESS] ✅ Blob list has been saved to ${SHARED_DIR}/blob_top_level_folders.txt"
  cp "${SHARED_DIR}/blob_top_level_folders.txt" "${ARTIFACT_DIR}/blob_top_level_folders.txt"
  echo "[SUCCESS] ✅ Blob list has also been copied to ARTIFACT_DIR"
else
  echo "[ERROR] ❌ Failed to create blob list file"
  exit 1
fi

echo "[INFO] 🔍 Finding all .pulumi/locks/ blobs in container ${AZURE_STORAGE_BLOB}..."

# Get unique top-level folders that have .pulumi/locks/
az storage blob list \
  --container-name "${AZURE_STORAGE_BLOB}" \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --account-key "${AZURE_STORAGE_KEY}" \
  --output json | \
  jq -r '.[].name | select(contains("/.pulumi/locks/")) | split("/.pulumi/locks/")[0]' | \
  sort -u > "${SHARED_DIR}/folders_with_locks.txt"

if [ ! -s "${SHARED_DIR}/folders_with_locks.txt" ]; then
  echo "[INFO] 🫙 No .pulumi/locks/ directories found in container"
  exit 0
fi

folder_count=$(wc -l < "${SHARED_DIR}/folders_with_locks.txt")
echo "[INFO] 📋 Found ${folder_count} folders with .pulumi/locks/ to clean"

# Delete all lock blobs in one efficient command
echo "[INFO] 🗑️ Deleting all .pulumi/locks/ blobs across all folders..."
az storage blob delete-batch \
  --source "${AZURE_STORAGE_BLOB}" \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --account-key "${AZURE_STORAGE_KEY}" \
  --pattern "*/.pulumi/locks/*"
cp "${SHARED_DIR}/folders_with_locks.txt" "${ARTIFACT_DIR}/folders_cleaned.txt"

echo "[SUCCESS] ✅ Successfully deleted .pulumi/locks/ from ${folder_count} folders"
