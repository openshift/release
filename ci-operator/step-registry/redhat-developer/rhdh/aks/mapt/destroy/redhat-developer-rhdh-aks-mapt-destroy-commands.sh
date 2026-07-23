#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

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

export PULUMI_K8S_DELETE_UNREACHABLE=true
  echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "[INFO] 🏷️ Setting CORRELATE_MAPT..."
CORRELATE_MAPT="aks-${BUILD_ID}"

echo "[INFO] 🗑️ Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

# Temporarily disable exit on error to capture failures
set +o errexit

# Capture both stdout and stderr to check for errors
output=$(mapt azure aks destroy \
  --project-name "aks" \
  --backed-url "azblob://${AZURE_STORAGE_BLOB}/${CORRELATE_MAPT}" 2>&1)
exit_code=$?

# Re-enable exit on error
set -o errexit

# Check if the stack is locked
if echo "$output" | grep -qiE "the stack is currently locked"; then
  echo "$output"
  echo "[WARN] ⚠️ Stack is currently locked, skipping destroy operations for ${CORRELATE_MAPT}"
  echo "Possible reasons:"
  echo "  a) Job was interrupted/cancelled: destroy post-step ran before create pre-step finished."
  echo "     Cleanup will be handled by the trap in the create pre-step."
  echo "  b) Other error occurred: infrastructure will be cleaned up by the weekly destroy-orphaned job."
  exit 0
fi

# Check for both exit code and error patterns in output
if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
  echo "$output"
  echo "[SUCCESS] ✅ Successfully destroyed MAPT: ${CORRELATE_MAPT}"
else
  echo "$output"
  echo "[ERROR] ❌ Failed to destroy MAPT: ${CORRELATE_MAPT}"
  exit 1
fi