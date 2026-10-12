#!/bin/bash

set -e

echo "[INFO] 🔐 Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "[SUCCESS] ✅ AWS credentials loaded successfully"

echo "[INFO] 📋 Listing top-level prefixes from S3 bucket ${AWS_S3_BUCKET}..."
aws s3api list-objects-v2 \
  --bucket "${AWS_S3_BUCKET}" \
  --delimiter "/" \
  --output json | \
  jq -r '.CommonPrefixes[]?.Prefix | rtrimstr("/")' | \
  sort -u > "${SHARED_DIR}/s3_top_level_folders.txt"

if [ -f "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "[SUCCESS] ✅ S3 object list has been saved to ${SHARED_DIR}/s3_top_level_folders.txt"
  cp "${SHARED_DIR}/s3_top_level_folders.txt" "${ARTIFACT_DIR}/s3_top_level_folders.txt"
  echo "[SUCCESS] ✅ S3 object list has also been copied to ARTIFACT_DIR"
else
  echo "[ERROR] ❌ Failed to create S3 object list file"
  exit 1
fi

echo "[INFO] 🔍 Finding all .pulumi/locks/ directories in S3 bucket ${AWS_S3_BUCKET}..."

# Get unique top-level folders that have .pulumi/locks/
aws s3api list-objects-v2 \
  --bucket "${AWS_S3_BUCKET}" \
  --output json \
  --query 'Contents[?contains(Key, `.pulumi/locks/`)].Key' \
  | jq -r '.[]?' \
  | sed 's|/\.pulumi/locks/.*||' \
  | sort -u > "${SHARED_DIR}/folders_with_locks.txt"

if [ ! -s "${SHARED_DIR}/folders_with_locks.txt" ]; then
  echo "[INFO] 🫙 No .pulumi/locks/ directories found in bucket"
  exit 0
fi

folder_count=$(wc -l < "${SHARED_DIR}/folders_with_locks.txt")
echo "[INFO] 📋 Found ${folder_count} folders with .pulumi/locks/ to clean"

# Delete all lock files in one efficient command
echo "[INFO] 🗑️ Deleting all .pulumi/locks/ files across all folders..."
aws s3 rm "s3://${AWS_S3_BUCKET}/" \
  --recursive \
  --exclude "*" \
  --include "*/.pulumi/locks/*"
cp "${SHARED_DIR}/folders_with_locks.txt" "${ARTIFACT_DIR}/folders_cleaned.txt"

echo "[SUCCESS] ✅ Successfully deleted .pulumi/locks/ from ${folder_count} folders"
