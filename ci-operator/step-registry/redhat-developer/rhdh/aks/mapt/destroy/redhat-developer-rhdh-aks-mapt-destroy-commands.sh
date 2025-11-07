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

export PULUMI_K8S_DELETE_UNREACHABLE=true
echo "PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "Loading CORRELATE_MAPT from ${SHARED_DIR}..."
CORRELATE_MAPT=$(cat ${SHARED_DIR}/CORRELATE_MAPT)
FOLDER_NAME="aks-${CORRELATE_MAPT}"
echo "Using folder: ${FOLDER_NAME}"

echo "Destroying MAPT infrastructure for ${FOLDER_NAME}..."
mapt azure aks destroy \
  --project-name "aks" \
  --backed-url "azblob://${AZURE_STORAGE_BLOB}/${FOLDER_NAME}"

echo "MAPT destroy completed successfully"

echo "Deleting folder ${FOLDER_NAME}/ from Azure Blob Storage..."
az storage blob delete-batch \
  --source "${AZURE_STORAGE_BLOB}" \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --account-key "${AZURE_STORAGE_KEY}" \
  --pattern "${FOLDER_NAME}/*"

echo "Successfully deleted folder ${FOLDER_NAME} from blob container"