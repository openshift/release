#!/bin/bash

set -e

echo "Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "AWS credentials loaded successfully"

echo "Setting CORRELATE_MAPT..."
CORRELATE_MAPT="eks-${BUILD_ID}"

echo "Creating MAPT infrastructure for ${CORRELATE_MAPT}..."
mapt aws eks create \
  --project-name "eks" \
  --backed-url "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}" \
  --conn-details-output "${SHARED_DIR}" \
  --version 1.33 \
  --workers-max 3 \
  --workers-desired 3 \
  --cpus 2 \
  --memory 4 \
  --arch x86_64 \
  --spot \
  --addons aws-ebs-csi-driver,coredns,eks-pod-identity-agent,kube-proxy,vpc-cni \
  --load-balancer-controller \
  --tags app-code=rhdh-003,service-phase=dev,cost-center=726

echo "MAPT EKS cluster created successfully"
