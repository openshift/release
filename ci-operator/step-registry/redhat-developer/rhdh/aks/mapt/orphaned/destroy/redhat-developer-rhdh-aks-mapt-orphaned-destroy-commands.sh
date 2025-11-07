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
success_count=0
failed_count=0
echo "Found ${total} blob top-level folders to process"

# Create files to track results
SUCCESSFUL_DESTROYS="${ARTIFACT_DIR}/successful_destroys.txt"
FAILED_DESTROYS="${ARTIFACT_DIR}/failed_destroys.txt"
touch "${SUCCESSFUL_DESTROYS}"
touch "${FAILED_DESTROYS}"

# Temporarily disable exit on error to capture failures
set +e

# Iterate over each value
for BLOB_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  current=$((current + 1))
  echo "Processing MAPT: ${BLOB_TOP_LEVEL_FOLDER} ($current/$total)"

  # Skip empty lines
  [ -z "$BLOB_TOP_LEVEL_FOLDER" ] && echo "Skipping empty folder name" && continue

  echo "Destroying MAPT for folder: ${BLOB_TOP_LEVEL_FOLDER}"
  if mapt azure aks destroy \
      --project-name "aks" \
      --backed-url "azblob://${AZURE_STORAGE_BLOB}/${BLOB_TOP_LEVEL_FOLDER}"; then
    echo "✅ Successfully destroyed MAPT: ${BLOB_TOP_LEVEL_FOLDER}"
    echo "${BLOB_TOP_LEVEL_FOLDER}" >> "${SUCCESSFUL_DESTROYS}"
    success_count=$((success_count + 1))
  else
    echo "❌ Failed to destroy MAPT: ${BLOB_TOP_LEVEL_FOLDER}"
    echo "${BLOB_TOP_LEVEL_FOLDER}" >> "${FAILED_DESTROYS}"
    failed_count=$((failed_count + 1))
  fi
done

# Re-enable exit on error
set -e

echo ""
echo "==== Destroy Summary ===="
echo "Total processed: ${total}"
echo "Successful: ${success_count}"
echo "Failed: ${failed_count}"

# Batch delete successfully destroyed folders from Azure Blob Storage
if [ "${success_count}" -gt 0 ]; then
  echo ""
  echo "Deleting ${success_count} successfully destroyed folders from Azure Blob Storage..."

  while IFS= read -r folder; do
    if [ -n "$folder" ]; then
      echo "Deleting ${folder}/ from container ${AZURE_STORAGE_BLOB}..."
      az storage blob delete-batch \
        --source "${AZURE_STORAGE_BLOB}" \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        --account-key "${AZURE_STORAGE_KEY}" \
        --pattern "${folder}/*"
    fi
  done < "${SUCCESSFUL_DESTROYS}"

  echo "🎉 Successfully deleted all folders from Azure Blob Storage"
else
  echo "🫙 No folders to delete from Azure Blob Storage"
fi

echo ""
echo "Finished processing all ${total} MAPT folders"

# Exit with failure if any destroys failed
if [ "${failed_count}" -gt 0 ]; then
  echo "⚠️  Exiting with failure due to ${failed_count} failed destroy(s)"
  exit 1
fi

echo "✅ All operations completed successfully"