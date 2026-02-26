#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  # Temporarily disable exit on error to capture failures
  set +o errexit

  echo "[INFO] **** Starting emergency cleanup for failed cluster creation..."

  if [[ -n "${DYNAMIC_BUCKET_NAME:-}" ]]; then
    export PULUMI_K8S_DELETE_UNREACHABLE=true
    echo "[INFO] **** Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

    echo "[INFO] **** Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

    # Capture both stdout and stderr to check for errors
    output=$(mapt aws openshift-snc destroy \
      --project-name "${CORRELATE_MAPT}" \
      --backed-url "s3://${DYNAMIC_BUCKET_NAME}" 2>&1)
    exit_code=$?

    echo "$output"
    if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
      echo "[SUCCESS] !!!! Successfully destroyed MAPT infrastructure during cleanup"
    else
      echo "[WARN] WARN MAPT destroy may have failed, but continuing with bucket cleanup"
    fi

    echo "[INFO] **** Emergency cleanup: Deleting S3 bucket: ${DYNAMIC_BUCKET_NAME}..."

    # Emergency cleanup: delete all objects and versions, then bucket
    aws s3 rm "s3://${DYNAMIC_BUCKET_NAME}" --recursive 2>/dev/null || true

    # List and delete object versions (simplified approach for emergency cleanup)
    aws s3api list-object-versions --bucket "${DYNAMIC_BUCKET_NAME}" --output json 2>/dev/null | \
    jq -r '.Versions[]?, .DeleteMarkers[]? | "aws s3api delete-object --bucket '${DYNAMIC_BUCKET_NAME}' --key \"" + .Key + "\" --version-id " + .VersionId' | \
    head -100 | bash 2>/dev/null || true

    # Delete the bucket
    aws s3 rb "s3://${DYNAMIC_BUCKET_NAME}" 2>/dev/null || echo "[WARN] WARN Bucket deletion failed or bucket already deleted"

    echo "[INFO] !!!! Emergency S3 bucket cleanup attempted"
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

echo "[INFO] AUTH Loading AWS credentials from vault..."
aws_validation
echo "[SUCCESS] !!!! AWS credentials loaded successfully"

echo "[INFO] TAG Setting CORRELATE_MAPT..."
CORRELATE_MAPT="ossm-istio-snc-${BUILD_ID}"
export CORRELATE_MAPT

echo "[INFO] BUCKET Creating dynamic S3 bucket for MAPT state storage..."
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

echo "[SUCCESS] !!!! S3 bucket created: ${DYNAMIC_BUCKET_NAME}"

# Save bucket name for cleanup by destroy step
echo "${DYNAMIC_BUCKET_NAME}" > "${SHARED_DIR}/mapt-s3-bucket-name"
echo "[INFO] SAVE Saved bucket name to ${SHARED_DIR}/mapt-s3-bucket-name for cleanup"

# Trap TERM signal (job was interrupted/cancelled) into cleanup function to ensure MAPT infrastructure is destroyed
trap cleanup TERM

# Set OpenShift SNC configuration with environment variables for flexibility
OCP_VERSION=${OCP_VERSION:-"4.20.0"}
CPU=${CPU:-"8"}
MEMORY=${MEMORY:-"32"}
SPOT=${SPOT:-"true"}
SPOT_INCREASE_RATE=${SPOT_INCREASE_RATE:-"40"}
MAPT_TAGS=${MAPT_TAGS:-"ci=true,repo=openshift-servicemesh"}

echo "[INFO] START Creating OSSM Istio MAPT OpenShift SNC infrastructure for ${CORRELATE_MAPT}..."
echo "[INFO] LOC Using S3 state backend: s3://${DYNAMIC_BUCKET_NAME}"
echo "[INFO] INFO SNC Configuration: OpenShift ${OCP_VERSION}, ${CPU} CPU, ${MEMORY}GB RAM, spot=${SPOT}"

mapt aws openshift-snc create \
  --backed-url "s3://${DYNAMIC_BUCKET_NAME}" \
  --conn-details-output "${SHARED_DIR}" \
  --pull-secret-file /tmp/secrets/pull-secret \
  --project-name "${CORRELATE_MAPT}" \
  --tags "project=crc,${MAPT_TAGS}" \
  --version "${OCP_VERSION}" \
  --cpus "${CPU}" \
  --memory "${MEMORY}" \
  --spot \
  --spot-increase-rate "${SPOT_INCREASE_RATE}"

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "[ERROR] ERROR kubeconfig file not found at ${SHARED_DIR}/kubeconfig"
  echo "[ERROR] ERROR Failed to create MAPT OpenShift SNC cluster"
  exit 1
fi
echo "[SUCCESS] !!!! OSSM Istio MAPT OpenShift SNC cluster created successfully"

echo "[INFO] SAVE Saving kubeconfig location for test step..."
echo "[INFO] FILE Kubeconfig available at: ${SHARED_DIR}/kubeconfig"

echo "[SUCCESS] !!!! MAPT OpenShift SNC cluster ready for testing"
echo "[INFO] INFO Namespace and pod security setup will be handled by test step"