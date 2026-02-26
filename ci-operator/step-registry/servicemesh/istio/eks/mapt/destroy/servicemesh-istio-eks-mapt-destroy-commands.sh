#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Function to properly delete a versioned S3 bucket
delete_versioned_bucket() {
  local bucket_name="$1"
  echo "[INFO] 🗑️ Deleting versioned S3 bucket: ${bucket_name}..."

  # Temporarily disable exit on error for cleanup operations
  set +o errexit

  # Step 1: Delete all current objects
  echo "[INFO] 🧹 Deleting all current objects..."
  aws s3 rm "s3://${bucket_name}" --recursive

  # Step 2: Delete all object versions and delete markers
  echo "[INFO] 🗂️ Deleting all object versions and delete markers..."

  # List all object versions and delete markers
  aws s3api list-object-versions --bucket "${bucket_name}" --output json > /tmp/s3-versions.json 2>/dev/null || echo "{}" > /tmp/s3-versions.json

  # Delete all versions
  if jq -e '.Versions[]?' /tmp/s3-versions.json >/dev/null 2>&1; then
    echo "[INFO] 📦 Found object versions to delete..."
    jq -r '.Versions[]? | "{\\"Key\\": \\"" + .Key + "\\", \\"VersionId\\": \\"" + .VersionId + "\\"}"' /tmp/s3-versions.json | \
    jq -s '{"Objects": [.[] | fromjson], "Quiet": true}' > /tmp/delete-versions.json

    if [ -s /tmp/delete-versions.json ] && jq -e '.Objects | length > 0' /tmp/delete-versions.json >/dev/null; then
      aws s3api delete-objects --bucket "${bucket_name}" --delete file:///tmp/delete-versions.json
    fi
  fi

  # Delete all delete markers
  if jq -e '.DeleteMarkers[]?' /tmp/s3-versions.json >/dev/null 2>&1; then
    echo "[INFO] 🏷️ Found delete markers to clean up..."
    jq -r '.DeleteMarkers[]? | "{\\"Key\\": \\"" + .Key + "\\", \\"VersionId\\": \\"" + .VersionId + "\\"}"' /tmp/s3-versions.json | \
    jq -s '{"Objects": [.[] | fromjson], "Quiet": true}' > /tmp/delete-markers.json

    if [ -s /tmp/delete-markers.json ] && jq -e '.Objects | length > 0' /tmp/delete-markers.json >/dev/null; then
      aws s3api delete-objects --bucket "${bucket_name}" --delete file:///tmp/delete-markers.json
    fi
  fi

  # Step 3: Delete the empty bucket
  echo "[INFO] 🪣 Deleting empty bucket..."
  aws s3 rb "s3://${bucket_name}"
  local delete_result=$?

  # Cleanup temp files
  rm -f /tmp/s3-versions.json /tmp/delete-versions.json /tmp/delete-markers.json

  # Re-enable exit on error
  set -o errexit

  return $delete_result
}

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
  if delete_versioned_bucket "${DYNAMIC_BUCKET_NAME}"; then
    echo "[SUCCESS] ✅ Successfully deleted S3 bucket despite locked stack"
  else
    echo "[WARN] ⚠️ Could not delete bucket, may already be in use or locked"
  fi
  exit 0
fi

# Check for both exit code and error patterns in output
if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
  echo "$output"
  echo "[SUCCESS] ✅ Successfully destroyed OSSM Istio MAPT: ${CORRELATE_MAPT}"

  # Use the comprehensive versioned bucket deletion function
  if delete_versioned_bucket "${DYNAMIC_BUCKET_NAME}"; then
    echo "[SUCCESS] ✅ Successfully deleted S3 bucket: ${DYNAMIC_BUCKET_NAME}"
  else
    echo "[WARN] ⚠️ Failed to delete S3 bucket: ${DYNAMIC_BUCKET_NAME}"
    echo "[WARN] ⚠️ Bucket may still contain objects or may have versioning conflicts"
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