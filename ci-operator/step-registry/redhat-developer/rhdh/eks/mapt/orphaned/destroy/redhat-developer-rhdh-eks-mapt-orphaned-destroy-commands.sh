#!/bin/bash

OVERALL_EXIT_CODE=0

# shellcheck disable=SC2317
handle_error() {
  echo "An error occurred"
  # Additional error handling logic
  OVERALL_EXIT_CODE=1
}

# Set the error handler function
trap handle_error ERR

AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET

# Read the array from file
mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/s3_top_level_folders.txt"

total=${#CORRELATE_MAPT_ARRAY[@]}
current=0
# Iterate over each value
for S3_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  ((current++))
  echo "Processing MAPT: ${S3_TOP_LEVEL_FOLDER} ($current/$total)"

  # Skip empty lines
  [ -z "$S3_TOP_LEVEL_FOLDER" ] && continue

  mapt aws eks destroy \
      --project-name "eks" \
      --backed-url "s3://${AWS_S3_BUCKET}/${S3_TOP_LEVEL_FOLDER}"
done

exit $OVERALL_EXIT_CODE