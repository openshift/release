#!/bin/bash

set -e

echo "Loading Azure credentials from secrets..."
AZURE_STORAGE_ACCOUNT=$(cat /tmp/secrets/AZURE_STORAGE_ACCOUNT)
AZURE_STORAGE_BLOB=$(cat /tmp/secrets/AZURE_STORAGE_BLOB)
AZURE_STORAGE_KEY=$(cat /tmp/secrets/AZURE_STORAGE_KEY)
ARM_CLIENT_ID=$(cat /tmp/secrets/ARM_CLIENT_ID)
ARM_CLIENT_SECRET=$(cat /tmp/secrets/ARM_CLIENT_SECRET)
ARM_SUBSCRIPTION_ID=$(cat /tmp/secrets/ARM_SUBSCRIPTION_ID)
ARM_TENANT_ID=$(cat /tmp/secrets/ARM_TENANT_ID)
export AZURE_STORAGE_ACCOUNT AZURE_STORAGE_BLOB AZURE_STORAGE_KEY ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID
echo "Azure credentials loaded successfully"

echo "Reading blob top-level folders from ${SHARED_DIR}/blob_top_level_folders.txt..."

# Check if input file exists
if [ ! -f "${SHARED_DIR}/blob_top_level_folders.txt" ]; then
  echo "ERROR: Input file ${SHARED_DIR}/blob_top_level_folders.txt does not exist"
  exit 1
fi

# Check if input file is empty
if [ ! -s "${SHARED_DIR}/blob_top_level_folders.txt" ]; then
  echo "WARNING: Input file ${SHARED_DIR}/blob_top_level_folders.txt is empty"
  echo "No MAPT folders to process"
  exit 0
fi

mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/blob_top_level_folders.txt"

total=${#CORRELATE_MAPT_ARRAY[@]}
current=0
echo "Found ${total} blob top-level folders to process"

# Iterate over each value
for BLOB_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  current=$((current + 1))
  echo "Processing MAPT: ${BLOB_TOP_LEVEL_FOLDER} ($current/$total)"

  # Skip empty lines
  [ -z "$BLOB_TOP_LEVEL_FOLDER" ] && echo "Skipping empty folder name" && continue

  echo "Destroying MAPT for folder: ${BLOB_TOP_LEVEL_FOLDER}"
  mapt azure aks destroy \
      --project-name "aks" \
      --backed-url "azblob://${AZURE_STORAGE_BLOB}/${BLOB_TOP_LEVEL_FOLDER}"
  echo "Completed processing MAPT: ${BLOB_TOP_LEVEL_FOLDER}"
done

echo "Finished processing all ${total} MAPT folders"