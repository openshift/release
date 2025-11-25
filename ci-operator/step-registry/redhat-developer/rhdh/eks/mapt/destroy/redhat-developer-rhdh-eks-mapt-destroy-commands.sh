#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "[INFO] 🔐 Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "[SUCCESS] ✅ AWS credentials loaded successfully"

export PULUMI_K8S_DELETE_UNREACHABLE=true
  echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "[INFO] 🏷️ Setting CORRELATE_MAPT..."
CORRELATE_MAPT="eks-${BUILD_ID}"

echo "[INFO] 🗑️ Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

# Temporarily disable exit on error to capture failures
set +o errexit

# Capture both stdout and stderr to check for errors
output=$(mapt aws eks destroy \
  --project-name "eks" \
  --backed-url "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}" 2>&1)
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

  echo "[INFO] 🗑️ Deleting folder s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}/ from S3..."
  aws s3 rm "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}/" --recursive

  echo "[SUCCESS] ✅ Successfully deleted folder ${CORRELATE_MAPT} from S3 bucket"
else
  echo "$output"
  echo "[ERROR] ❌ Failed to destroy MAPT: ${CORRELATE_MAPT}"
  echo "[WARN] ⚠️ Skipping deletion of folder ${CORRELATE_MAPT} from S3 due to destroy failure"
  exit 1
fi