#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  # Temporarily disable exit on error to capture failures
  set +o errexit

  echo "[INFO] 🧹 Starting emergency cleanup for failed cluster creation..."

  if [[ -n "${DYNAMIC_BUCKET_NAME:-}" ]]; then
    export PULUMI_K8S_DELETE_UNREACHABLE=true
    echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

    echo "[INFO] 🗑️ Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

    # Capture both stdout and stderr to check for errors
    output=$(mapt aws eks destroy \
      --project-name "eks" \
      --backed-url "s3://${DYNAMIC_BUCKET_NAME}/${CORRELATE_MAPT}" 2>&1)
    exit_code=$?

    echo "$output"
    if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
      echo "[SUCCESS] ✅ Successfully destroyed MAPT infrastructure during cleanup"
    else
      echo "[WARN] ⚠️ MAPT destroy may have failed, but continuing with bucket cleanup"
    fi

    echo "[INFO] 🗑️ Emergency cleanup: Deleting S3 bucket: ${DYNAMIC_BUCKET_NAME}..."

    # Emergency cleanup: delete all objects and versions, then bucket
    aws s3 rm "s3://${DYNAMIC_BUCKET_NAME}" --recursive 2>/dev/null || true

    # List and delete object versions (simplified approach for emergency cleanup)
    aws s3api list-object-versions --bucket "${DYNAMIC_BUCKET_NAME}" --output json 2>/dev/null | \
    jq -r '.Versions[]?, .DeleteMarkers[]? | "aws s3api delete-object --bucket '${DYNAMIC_BUCKET_NAME}' --key \"" + .Key + "\" --version-id " + .VersionId' | \
    head -100 | bash 2>/dev/null || true

    # Delete the bucket
    aws s3 rb "s3://${DYNAMIC_BUCKET_NAME}" 2>/dev/null || echo "[WARN] ⚠️ Bucket deletion failed or bucket already deleted"

    echo "[INFO] ✅ Emergency S3 bucket cleanup attempted"
  fi

  # Re-enable exit on error
  set -o errexit
  exit 1
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
export CORRELATE_MAPT

echo "[INFO] 🪣 Creating dynamic S3 bucket for MAPT state storage..."
DYNAMIC_BUCKET_NAME="ossm-mapt-${CORRELATE_MAPT}-$(date +%s)"
export DYNAMIC_BUCKET_NAME

# Create S3 bucket with region-specific configuration
if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  # us-east-1 doesn't need location constraint
  aws s3 mb "s3://${DYNAMIC_BUCKET_NAME}"
else
  # Other regions need location constraint
  aws s3 mb "s3://${DYNAMIC_BUCKET_NAME}" --region "${AWS_REGION}"
fi

# Enable versioning for Pulumi state safety
aws s3api put-bucket-versioning \
  --bucket "${DYNAMIC_BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

# Add bucket tags for cost tracking and identification
aws s3api put-bucket-tagging \
  --bucket "${DYNAMIC_BUCKET_NAME}" \
  --tagging 'TagSet=[
    {Key=app-code,Value=ossm-mapt},
    {Key=mapt-job,Value='${CORRELATE_MAPT}'},
    {Key=build-id,Value='${BUILD_ID}'},
    {Key=auto-cleanup,Value=true}
  ]'

echo "[SUCCESS] ✅ S3 bucket created: ${DYNAMIC_BUCKET_NAME}"

# Save bucket name for cleanup by destroy step
echo "${DYNAMIC_BUCKET_NAME}" > "${SHARED_DIR}/mapt-s3-bucket-name"
echo "[INFO] 💾 Saved bucket name to ${SHARED_DIR}/mapt-s3-bucket-name for cleanup"

# Trap TERM signal (job was interrupted/cancelled) into cleanup function to ensure MAPT infrastructure is destroyed
trap cleanup TERM

echo "[INFO] 🚀 Creating OSSM Istio MAPT EKS infrastructure for ${CORRELATE_MAPT}..."
echo "[INFO] 📍 Using S3 state backend: s3://${DYNAMIC_BUCKET_NAME}/${CORRELATE_MAPT}"
mapt aws eks create \
  --project-name "eks" \
  --backed-url "s3://${DYNAMIC_BUCKET_NAME}/${CORRELATE_MAPT}" \
  --conn-details-output "${SHARED_DIR}" \
  --version 1.34 \
  --workers-max 1 \
  --workers-desired 1 \
  --cpus 2 \
  --memory 4 \
  --arch x86_64 \
  --spot \
  --addons aws-ebs-csi-driver,coredns,eks-pod-identity-agent,kube-proxy,vpc-cni \
  --load-balancer-controller \
  --tags app-code=ossm-mapt,test-job-id="${JOB_ID:-${BUILD_ID}}",mapt="${CORRELATE_MAPT}",s3-bucket="${DYNAMIC_BUCKET_NAME}"

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "[ERROR] ❌ kubeconfig file not found at ${SHARED_DIR}/kubeconfig"
  echo "[ERROR] ❌ Failed to create MAPT EKS cluster"
  exit 1
fi
echo "[SUCCESS] ✅ OSSM Istio MAPT EKS cluster created successfully"

echo "[INFO] 💾 Saving kubeconfig location for test step..."
echo "[INFO] 📁 Kubeconfig available at: ${SHARED_DIR}/kubeconfig"

echo "[SUCCESS] ✅ MAPT EKS cluster ready for testing"
echo "[INFO] ℹ️ Namespace and pod security setup will be handled by test step"