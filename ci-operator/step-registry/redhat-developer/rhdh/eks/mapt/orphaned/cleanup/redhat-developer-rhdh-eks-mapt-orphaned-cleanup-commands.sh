#!/bin/bash

set -e

echo "[INFO] 🔐 Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "[SUCCESS] ✅ AWS credentials loaded successfully"

SUCCESSFUL_DESTROYS="${SHARED_DIR}/successful_destroys.txt"

if [ ! -f "${SUCCESSFUL_DESTROYS}" ] || [ ! -s "${SUCCESSFUL_DESTROYS}" ]; then
  echo "[INFO] 🫙 No successfully destroyed folders to clean up from S3"
  exit 0
fi

success_count=$(wc -l < "${SUCCESSFUL_DESTROYS}")
echo "[INFO] 🗑️ Deleting ${success_count} successfully destroyed folders from S3 bucket..."

while IFS= read -r folder; do
  if [ -n "$folder" ]; then
    echo "[INFO] 🗑️ Deleting s3://${AWS_S3_BUCKET}/${folder}/..."
    aws s3 rm "s3://${AWS_S3_BUCKET}/${folder}/" --recursive
  fi
done < "${SUCCESSFUL_DESTROYS}"

echo "[SUCCESS] ✅ Successfully deleted all folders from S3"
