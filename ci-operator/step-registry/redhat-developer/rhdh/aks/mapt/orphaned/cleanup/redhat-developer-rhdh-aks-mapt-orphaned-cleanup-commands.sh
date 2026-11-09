#!/bin/bash

set -e

echo "[INFO] 🔐 Loading Azure credentials from secrets..."
AZURE_STORAGE_ACCOUNT=$(cat /tmp/secrets/AZURE_STORAGE_ACCOUNT)
AZURE_STORAGE_BLOB=$(cat /tmp/secrets/AZURE_STORAGE_BLOB)
AZURE_STORAGE_KEY=$(cat /tmp/secrets/AZURE_STORAGE_KEY)
export AZURE_STORAGE_ACCOUNT AZURE_STORAGE_BLOB AZURE_STORAGE_KEY
echo "[SUCCESS] ✅ Azure credentials loaded successfully"

SUCCESSFUL_DESTROYS="${SHARED_DIR}/successful_destroys.txt"

if [ ! -f "${SUCCESSFUL_DESTROYS}" ] || [ ! -s "${SUCCESSFUL_DESTROYS}" ]; then
  echo "[INFO] 🫙 No successfully destroyed folders to clean up from Azure Blob Storage"
  exit 0
fi

success_count=$(wc -l < "${SUCCESSFUL_DESTROYS}")
echo "[INFO] 🗑️ Deleting ${success_count} successfully destroyed folders from Azure Blob Storage..."

while IFS= read -r folder; do
  if [ -n "$folder" ]; then
    echo "[INFO] 🗑️ Deleting ${folder}/ from container ${AZURE_STORAGE_BLOB}..."
    az storage blob delete-batch \
      --source "${AZURE_STORAGE_BLOB}" \
      --account-name "${AZURE_STORAGE_ACCOUNT}" \
      --account-key "${AZURE_STORAGE_KEY}" \
      --pattern "${folder}/*"
  fi
done < "${SUCCESSFUL_DESTROYS}"

echo "[SUCCESS] ✅ Successfully deleted all folders from Azure Blob Storage"
