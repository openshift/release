#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

aws_validation() {
  echo "========== AWS Validation =========="
  echo "Validating AWS credentials..."
  CRED_FILE=""
  if [ -f "/tmp/secrets/.awscred" ]; then
    CRED_FILE="/tmp/secrets/.awscred"
  elif [ -f "/tmp/secrets/config" ]; then
    CRED_FILE="/tmp/secrets/config"
  else
    echo "Error: AWS credentials file not found (looked for .awscred and config)"
    exit 1
  fi

  echo "Using credentials file: ${CRED_FILE}"

  export AWS_SHARED_CREDENTIALS_FILE="${CRED_FILE}"
  AWS_REGION=${AWS_REGION:-"us-east-1"}
  export AWS_REGION
}

echo "[INFO] 🔐 Loading AWS credentials from vault..."
aws_validation
echo "[SUCCESS] ✅ AWS credentials loaded successfully"

echo "[INFO] 🏷️ Setting CORRELATE_MAPT..."
CORRELATE_MAPT="ossm-istio-eks-${BUILD_ID}"

echo "[INFO] 📖 Reading dynamic S3 bucket name from shared directory..."
if [[ ! -f "${SHARED_DIR}/mapt-s3-bucket-name" ]]; then
  echo "[ERROR] ❌ Bucket name file not found at ${SHARED_DIR}/mapt-s3-bucket-name"
  echo "[ERROR] ❌ Cannot proceed with cleanup without bucket name"
  exit 1
fi

DYNAMIC_BUCKET_NAME=$(cat "${SHARED_DIR}/mapt-s3-bucket-name")
export DYNAMIC_BUCKET_NAME
echo "[SUCCESS] ✅ Retrieved bucket name: ${DYNAMIC_BUCKET_NAME}"

export PULUMI_K8S_DELETE_UNREACHABLE=true
echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "[INFO] 🗑️ Destroying OSSM Istio MAPT infrastructure for ${CORRELATE_MAPT}..."
echo "[INFO] 📍 Using S3 state backend: s3://${DYNAMIC_BUCKET_NAME}/${CORRELATE_MAPT}"

# Temporarily disable exit on error to capture failures
set +o errexit

# Capture both stdout and stderr to check for errors
output=$(mapt aws eks destroy \
  --project-name "eks" \
  --backed-url "s3://${DYNAMIC_BUCKET_NAME}/${CORRELATE_MAPT}" 2>&1)
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

  # Even if stack is locked, we should try to clean up the S3 bucket
  echo "[INFO] 🪣 Attempting to clean up S3 bucket despite locked stack..."
  set +o errexit
  aws s3 rb "s3://${DYNAMIC_BUCKET_NAME}" --force 2>/dev/null || echo "[WARN] ⚠️ Could not delete bucket, may already be in use"
  set -o errexit
  exit 0
fi

# Check for both exit code and error patterns in output
if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
  echo "$output"
  echo "[SUCCESS] ✅ Successfully destroyed OSSM Istio MAPT: ${CORRELATE_MAPT}"

  echo "[INFO] 🪣 Deleting entire S3 bucket: ${DYNAMIC_BUCKET_NAME}..."

  # Temporarily disable exit on error for bucket cleanup
  set +o errexit

  # Force delete bucket and all contents
  aws s3 rb "s3://${DYNAMIC_BUCKET_NAME}" --force
  bucket_delete_exit_code=$?

  # Re-enable exit on error
  set -o errexit

  if [ $bucket_delete_exit_code -eq 0 ]; then
    echo "[SUCCESS] ✅ Successfully deleted S3 bucket: ${DYNAMIC_BUCKET_NAME}"
  else
    echo "[WARN] ⚠️ Failed to delete S3 bucket: ${DYNAMIC_BUCKET_NAME}"
    echo "[WARN] ⚠️ Bucket may still contain objects or may already be deleted"
  fi

  # Clean up the bucket name file
  rm -f "${SHARED_DIR}/mapt-s3-bucket-name" || true

  echo "[SUCCESS] ✅ OSSM Istio MAPT cleanup completed successfully"
else
  echo "$output"
  echo "[ERROR] ❌ Failed to destroy OSSM Istio MAPT: ${CORRELATE_MAPT}"
  echo "[WARN] ⚠️ Skipping S3 bucket deletion due to MAPT destroy failure"
  echo "[WARN] ⚠️ Bucket ${DYNAMIC_BUCKET_NAME} may need manual cleanup"
  exit 1
fi