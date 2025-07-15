#!/bin/bash

set -e

AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET

# List all top-level prefixes in the S3 bucket and save to file
echo "Listing top-level prefixes from S3 bucket ${AWS_S3_BUCKET}..."
aws s3api list-objects-v2 \
  --bucket "${AWS_S3_BUCKET}" \
  --delimiter "/" \
  --output json | \
  jq -r '.CommonPrefixes[]?.Prefix | rtrimstr("/")' | \
  sort -u > "${SHARED_DIR}/s3_top_level_folders.txt"

if [ -f "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "S3 object list has been saved to ${SHARED_DIR}/s3_top_level_folders.txt"
else
  echo "Error: Failed to create S3 object list file"
  exit 1
fi