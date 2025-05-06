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

# Read the array from file
mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/blob_top_level_folders.txt"

# Iterate over each value
for BLOB_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  # Skip empty lines
  [ -z "$BLOB_TOP_LEVEL_FOLDER" ] && continue

  echo "Processing MAPT: ${BLOB_TOP_LEVEL_FOLDER}"

  mapt azure aks destroy \
      --project-name "aks" \
      --backed-url "azblob://${AZURE_STORAGE_BLOB}/${BLOB_TOP_LEVEL_FOLDER}"
done