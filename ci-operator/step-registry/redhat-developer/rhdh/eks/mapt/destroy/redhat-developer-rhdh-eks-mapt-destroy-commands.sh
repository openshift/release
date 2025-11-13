#!/bin/bash

set -e

echo "Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "AWS credentials loaded successfully"

export PULUMI_K8S_DELETE_UNREACHABLE=true
echo "PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "Setting CORRELATE_MAPT..."
CORRELATE_MAPT="eks-${BUILD_ID}"

echo "Destroying MAPT infrastructure for ${CORRELATE_MAPT}..."
mapt aws eks destroy \
  --project-name "eks" \
  --backed-url "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}"

echo "MAPT destroy completed successfully"

echo "Deleting folder s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}/ from S3..."
aws s3 rm "s3://${AWS_S3_BUCKET}/${CORRELATE_MAPT}/" --recursive

echo "Successfully deleted folder ${CORRELATE_MAPT} from S3 bucket"