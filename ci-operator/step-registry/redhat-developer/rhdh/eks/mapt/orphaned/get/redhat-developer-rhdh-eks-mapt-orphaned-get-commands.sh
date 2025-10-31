#!/bin/bash

set -e

echo "Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "AWS credentials loaded successfully"

echo "Listing top-level prefixes from S3 bucket ${AWS_S3_BUCKET}..."
aws s3api list-objects-v2 \
  --bucket "${AWS_S3_BUCKET}" \
  --delimiter "/" \
  --output json | \
  jq -r '.CommonPrefixes[]?.Prefix | rtrimstr("/")' | \
  sort -u > "${SHARED_DIR}/s3_top_level_folders.txt"

if [ -f "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "S3 object list has been saved to ${SHARED_DIR}/s3_top_level_folders.txt"
  cp "${SHARED_DIR}/s3_top_level_folders.txt" "${ARTIFACT_DIR}/s3_top_level_folders.txt"
  echo "S3 object list has also been copied to ARTIFACT_DIR"
else
  echo "Error: Failed to create S3 object list file"
  exit 1
fi

# Check if input file is empty
if [ ! -s "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "WARNING: Input file ${SHARED_DIR}/s3_top_level_folders.txt is empty"
  echo "No S3 folders to process"
  exit 0
fi

mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/s3_top_level_folders.txt"

total=${#CORRELATE_MAPT_ARRAY[@]}
current=0
echo "Found ${total} S3 top-level folders to process"

echo "Deleting .pulumi/locks/ folders from each top-level prefix..."
for S3_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  current=$((current + 1))
  echo "Processing folder: ${S3_TOP_LEVEL_FOLDER} ($current/$total)"

  [ -z "$S3_TOP_LEVEL_FOLDER" ] && echo "Skipping empty folder name" && continue

  echo "Checking for .pulumi/locks/ in ${S3_TOP_LEVEL_FOLDER}..."
  # Check if .pulumi/locks/ prefix exists before attempting deletion
  if aws s3 ls "s3://${AWS_S3_BUCKET}/${S3_TOP_LEVEL_FOLDER}/.pulumi/locks/" >/dev/null 2>&1; then
    echo "Deleting s3://${AWS_S3_BUCKET}/${S3_TOP_LEVEL_FOLDER}/.pulumi/locks/..."
    aws s3 rm "s3://${AWS_S3_BUCKET}/${S3_TOP_LEVEL_FOLDER}/.pulumi/locks/" --recursive
    echo "Successfully deleted .pulumi/locks/ from ${S3_TOP_LEVEL_FOLDER}"
  else
    echo "No .pulumi/locks/ folder found in ${S3_TOP_LEVEL_FOLDER}, skipping"
  fi
done

echo "Finished processing all ${total} S3 folders"
