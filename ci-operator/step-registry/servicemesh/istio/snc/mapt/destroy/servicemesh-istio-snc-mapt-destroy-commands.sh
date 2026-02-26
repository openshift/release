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

echo "[INFO] AUTH Loading AWS credentials from vault..."
aws_validation
echo "[SUCCESS] !!!! AWS credentials loaded successfully"

echo "[INFO] TAG Setting CORRELATE_MAPT..."
CORRELATE_MAPT="ossm-istio-snc-${BUILD_ID}"

echo "[INFO] READ Reading dynamic S3 bucket name from shared directory..."
if [[ ! -f "${SHARED_DIR}/mapt-s3-bucket-name" ]]; then
  echo "[ERROR] ERROR Bucket name file not found at ${SHARED_DIR}/mapt-s3-bucket-name"
  echo "[ERROR] ERROR Cannot proceed with cleanup without bucket name"
  exit 1
fi

DYNAMIC_BUCKET_NAME=$(cat "${SHARED_DIR}/mapt-s3-bucket-name")
export DYNAMIC_BUCKET_NAME
echo "[SUCCESS] !!!! Retrieved bucket name: ${DYNAMIC_BUCKET_NAME}"

export PULUMI_K8S_DELETE_UNREACHABLE=true
echo "[INFO] **** Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "[INFO] **** Destroying OSSM Istio MAPT SNC infrastructure for ${CORRELATE_MAPT}..."
echo "[INFO] LOC Using S3 state backend: s3://${DYNAMIC_BUCKET_NAME}"

# Simple destroy approach without timeout
echo "[INFO] TIME Starting MAPT SNC destroy..."
if mapt aws openshift-snc destroy \
  --project-name "${CORRELATE_MAPT}" \
  --backed-url "s3://${DYNAMIC_BUCKET_NAME}"; then
  echo "[SUCCESS] !!!! Successfully destroyed OSSM Istio MAPT SNC: ${CORRELATE_MAPT}"

  # S3 bucket cleanup: first remove all files, then remove bucket
  echo "[INFO] **** Removing all objects from S3 bucket: ${DYNAMIC_BUCKET_NAME}"
  if aws s3 rm "s3://${DYNAMIC_BUCKET_NAME}" --recursive; then
    echo "[SUCCESS] !!!! All objects removed from bucket"

    echo "[INFO] **** Removing S3 bucket: ${DYNAMIC_BUCKET_NAME}"
    if aws s3 rb "s3://${DYNAMIC_BUCKET_NAME}"; then
      echo "[SUCCESS] !!!! Successfully deleted S3 bucket: ${DYNAMIC_BUCKET_NAME}"
    else
      echo "[WARN] WARN Failed to delete empty S3 bucket: ${DYNAMIC_BUCKET_NAME}"
      exit 1
    fi
  else
    echo "[WARN] WARN Failed to remove objects from S3 bucket: ${DYNAMIC_BUCKET_NAME}"
    exit 1
  fi

  # Clean up the bucket name file
  rm -f "${SHARED_DIR}/mapt-s3-bucket-name" || true

  echo "[SUCCESS] !!!! OSSM Istio MAPT SNC cleanup completed successfully"
else
  echo "[ERROR] ERROR MAPT SNC destroy failed"
  echo "[WARN] WARN Skipping S3 bucket deletion due to MAPT destroy failure"
  echo "[WARN] WARN Bucket ${DYNAMIC_BUCKET_NAME} may need manual cleanup"
  exit 1
fi