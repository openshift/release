#!/bin/bash

set -e

AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET

CORRELATE_MAPT=$(cat ${SHARED_DIR}/CORRELATE_MAPT)

mapt aws eks destroy \
  --project-name "eks" \
  --backed-url "s3://${AWS_S3_BUCKET}/eks-${CORRELATE_MAPT}"