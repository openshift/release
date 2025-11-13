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

echo "Setting CORRELATE_MAPT..."
CORRELATE_MAPT="eks-${BUILD_ID}"

echo "Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."
mapt azure aks destroy \
  --project-name "aks" \
  --backed-url "azblob://${AZURE_STORAGE_BLOB}/${CORRELATE_MAPT}"

echo "MAPT destroy completed successfully"

echo "Deleting folder ${CORRELATE_MAPT}/ from Azure Blob Storage..."
az storage blob delete-batch \
  --source "${AZURE_STORAGE_BLOB}" \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --account-key "${AZURE_STORAGE_KEY}" \
  --pattern "${CORRELATE_MAPT}/*"

echo "Successfully deleted folder ${CORRELATE_MAPT} from blob container"