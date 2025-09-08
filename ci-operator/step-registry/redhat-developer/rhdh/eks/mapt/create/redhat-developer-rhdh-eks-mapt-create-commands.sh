#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET


echo "$RANDOM$RANDOM" > ${SHARED_DIR}/CORRELATE_MAPT
CORRELATE_MAPT=$(cat ${SHARED_DIR}/CORRELATE_MAPT)

echo "Starting EKS cluster creation with mapt..."
echo "Project name: eks"
echo "Backend URL: s3://${AWS_S3_BUCKET}/eks-${CORRELATE_MAPT}"
echo "Connection details output: ${SHARED_DIR}"

# Execute mapt command with explicit error handling
if ! mapt aws eks create \
  --project-name "eks" \
  --backed-url "s3://${AWS_S3_BUCKET}/eks-${CORRELATE_MAPT}" \
  --conn-details-output "${SHARED_DIR}" \
  --version 1.31 \
  --workers-max 3 \
  --workers-desired 3 \
  --cpus 4 \
  --memory 4 \
  --arch x86_64 \
  --spot \
  --addons aws-ebs-csi-driver,coredns,eks-pod-identity-agent,kube-proxy,vpc-cni \
  --load-balancer-controller \
  --tags app-code=rhdh-003,service-phase=dev,cost-center=726; then
  echo "ERROR: mapt aws eks create command failed with exit code $?"
  exit 1
fi

# Validate that connection details were created
if [ ! -f "${SHARED_DIR}/kubeconfig" ] && [ ! -f "${SHARED_DIR}/cluster-info" ]; then
  echo "ERROR: EKS cluster creation failed - no connection details found in ${SHARED_DIR}"
  echo "Contents of ${SHARED_DIR}:"
  ls -la "${SHARED_DIR}" || true
  exit 1
fi

echo "EKS cluster creation completed successfully"
