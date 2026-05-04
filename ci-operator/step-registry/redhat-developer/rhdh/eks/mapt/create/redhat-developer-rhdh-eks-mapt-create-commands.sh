#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  # Temporarily disable exit on error to capture failures
  set +o errexit

  export PULUMI_K8S_DELETE_UNREACHABLE=true
    echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

  echo "[INFO] 🗑️ Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."

  # Capture both stdout and stderr to check for errors
  output=$(mapt aws eks destroy \
    --project-name "eks" \
    --backed-url "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}" \
    --force-destroy 2>&1)
  exit_code=$?

  # Re-enable exit on error
  set -o errexit

  # Check for both exit code and error patterns in output
  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
    echo "$output"
    echo "[SUCCESS] ✅ Successfully destroyed MAPT: ${CORRELATE_MAPT}"
  else
    echo "$output"
    echo "[ERROR] ❌ Failed to destroy MAPT: ${CORRELATE_MAPT}"
    exit 1
  fi
}

echo "[INFO] 🔐 Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "[SUCCESS] ✅ AWS credentials loaded successfully"

echo "[INFO] 🏷️ Setting CORRELATE_MAPT..."
CORRELATE_MAPT="eks-${BUILD_ID}"
export CORRELATE_MAPT

# Trap TERM signal (job was interrupted/cancelled) into cleanup function to ensure MAPT infrastructure is destroyed
trap cleanup TERM

echo "[INFO] 🚀 Creating MAPT infrastructure for ${CORRELATE_MAPT}..."
mapt aws eks create \
  --project-name "eks" \
  --backed-url "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}" \
  --conn-details-output "${SHARED_DIR}" \
  --version 1.34 \
  --workers-max 3 \
  --workers-desired 3 \
  --cpus 2 \
  --memory 4 \
  --arch x86_64 \
  --spot \
  --addons aws-ebs-csi-driver,coredns,eks-pod-identity-agent,kube-proxy,vpc-cni \
  --load-balancer-controller \
  --tags app-code=rhdh-003,service-phase=dev,cost-center=726
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "[ERROR] ❌ kubeconfig file not found at ${SHARED_DIR}/kubeconfig"
  echo "[ERROR] ❌ Failed to create MAPT EKS cluster"
  exit 1
fi
echo "[SUCCESS] ✅ MAPT EKS cluster created successfully"
