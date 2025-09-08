#!/bin/bash

set -e

AZURE_STORAGE_ACCOUNT=$(cat /tmp/secrets/AZURE_STORAGE_ACCOUNT)
AZURE_STORAGE_BLOB=$(cat /tmp/secrets/AZURE_STORAGE_BLOB)
AZURE_STORAGE_KEY=$(cat /tmp/secrets/AZURE_STORAGE_KEY)
ARM_CLIENT_ID=$(cat /tmp/secrets/ARM_CLIENT_ID)
ARM_CLIENT_SECRET=$(cat /tmp/secrets/ARM_CLIENT_SECRET)
ARM_SUBSCRIPTION_ID=$(cat /tmp/secrets/ARM_SUBSCRIPTION_ID)
ARM_TENANT_ID=$(cat /tmp/secrets/ARM_TENANT_ID)
export AZURE_STORAGE_ACCOUNT AZURE_STORAGE_BLOB AZURE_STORAGE_KEY ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID

echo "Authenticating to Azure..."
az login --service-principal \
  --username "${ARM_CLIENT_ID}" \
  --password "${ARM_CLIENT_SECRET}" \
  --tenant "${ARM_TENANT_ID}"

# Set the subscription
az account set --subscription "${ARM_SUBSCRIPTION_ID}"

# List all blobs in the container and save to file
echo "Listing blobs from container ${AZURE_STORAGE_BLOB}..."
az storage blob list \
  --container-name "${AZURE_STORAGE_BLOB}" \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --account-key "${AZURE_STORAGE_KEY}" \
  --output json  | \
  jq -r '.[].name | split("/")[0] | select(length > 0)' | \
  sort -u > "${SHARED_DIR}/blob_top_level_folders.txt"

if [ -f "${SHARED_DIR}/blob_top_level_folders.txt" ]; then
  echo "Blob list has been saved to ${SHARED_DIR}/blob_top_level_folders.txt"
else
  echo "Error: Failed to create blob list file"
  exit 1
fi