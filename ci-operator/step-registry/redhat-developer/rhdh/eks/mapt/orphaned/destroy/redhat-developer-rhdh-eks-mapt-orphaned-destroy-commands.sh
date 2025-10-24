#!/bin/bash

set -e

echo "Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "AWS credentials loaded successfully"

echo "Reading S3 top-level folders from ${SHARED_DIR}/s3_top_level_folders.txt..."

# Check if input file exists
if [ ! -f "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "ERROR: Input file ${SHARED_DIR}/s3_top_level_folders.txt does not exist"
  exit 1
fi

# Check if input file is empty
if [ ! -s "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "WARNING: Input file ${SHARED_DIR}/s3_top_level_folders.txt is empty"
  echo "No MAPT folders to process"
  exit 0
fi

mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/s3_top_level_folders.txt"

total=${#CORRELATE_MAPT_ARRAY[@]}
current=0
echo "Found ${total} S3 top-level folders to process"

for S3_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  current=$((current + 1))
  echo "Processing MAPT: ${S3_TOP_LEVEL_FOLDER} ($current/$total)"

  [ -z "$S3_TOP_LEVEL_FOLDER" ] && echo "Skipping empty folder name" && continue

  echo "Destroying MAPT for folder: ${S3_TOP_LEVEL_FOLDER}"
  mapt aws eks destroy \
      --project-name "eks" \
      --backed-url "s3://${AWS_S3_BUCKET}/${S3_TOP_LEVEL_FOLDER}"
  echo "Completed processing MAPT: ${S3_TOP_LEVEL_FOLDER}"
done

echo "Finished processing all ${total} MAPT folders"