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

echo "[INFO] 📋 Reading blob top-level folders from ${SHARED_DIR}/blob_top_level_folders.txt..."

# Check if input file exists
if [ ! -f "${SHARED_DIR}/blob_top_level_folders.txt" ]; then
  echo "[ERROR] ❌ Input file ${SHARED_DIR}/blob_top_level_folders.txt does not exist"
  exit 1
fi

# Check if input file is empty
if [ ! -s "${SHARED_DIR}/blob_top_level_folders.txt" ]; then
  echo "[WARN] ⚠️ Input file ${SHARED_DIR}/blob_top_level_folders.txt is empty"
  echo "[INFO] 🫙 No MAPT folders to process"
  exit 0
fi

mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/blob_top_level_folders.txt"

total=${#CORRELATE_MAPT_ARRAY[@]}
current=0
success_count=0
failed_count=0
echo "[INFO] 📋 Found ${total} blob top-level folders to process"

# Create files to track results
SUCCESSFUL_DESTROYS="${SHARED_DIR}/successful_destroys.txt"
FAILED_DESTROYS="${ARTIFACT_DIR}/failed_destroys.txt"
touch "${SUCCESSFUL_DESTROYS}"
touch "${FAILED_DESTROYS}"

# Temporarily disable exit on error to capture failures
set +e

# Iterate over each value
for BLOB_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  current=$((current + 1))
  echo "[INFO] 📋 Processing MAPT: ${BLOB_TOP_LEVEL_FOLDER} ($current/$total)"

  # Skip empty lines
  [ -z "$BLOB_TOP_LEVEL_FOLDER" ] && echo "[WARN] ⚠️ Skipping empty folder name" && continue

  echo "[INFO] 🗑️ Destroying MAPT for folder: ${BLOB_TOP_LEVEL_FOLDER}"
  
  # Capture both stdout and stderr to check for errors
  output=$(mapt azure aks destroy \
      --project-name "aks" \
      --backed-url "azblob://${AZURE_STORAGE_BLOB}/${BLOB_TOP_LEVEL_FOLDER}" 2>&1)
  exit_code=$?
  
  # Check for both exit code and error patterns in output
  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
    echo "$output"
    echo "[SUCCESS] ✅ Successfully destroyed MAPT: ${BLOB_TOP_LEVEL_FOLDER}"
    echo "${BLOB_TOP_LEVEL_FOLDER}" >> "${SUCCESSFUL_DESTROYS}"
    success_count=$((success_count + 1))
  else
    echo "$output"
    echo "[ERROR] ❌ Failed to destroy MAPT: ${BLOB_TOP_LEVEL_FOLDER}"
    echo "${BLOB_TOP_LEVEL_FOLDER}" >> "${FAILED_DESTROYS}"
    failed_count=$((failed_count + 1))
  fi
done

# Re-enable exit on error
set -e

echo "[INFO] 📊 Destroy Summary"
echo "[INFO]Total processed: ${total}"
echo "[INFO]Successful: ${success_count}"
echo "[INFO]Failed: ${failed_count}"

cp "${SUCCESSFUL_DESTROYS}" "${ARTIFACT_DIR}/successful_destroys.txt"

echo "[SUCCESS] ✅ Finished processing all ${total} MAPT folders"

# Exit with failure if any destroys failed
if [ "${failed_count}" -gt 0 ]; then
  echo "[WARN] ⚠️ Exiting with failure due to ${failed_count} failed destroy(s)"
  exit 1
fi

echo "[SUCCESS] ✅ All operations completed successfully"