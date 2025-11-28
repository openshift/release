#!/bin/bash

set -e

echo "[INFO] 🔐 Loading AWS credentials from secrets..."
AWS_ACCESS_KEY_ID=$(cat /tmp/secrets/AWS_ACCESS_KEY_ID)
AWS_SECRET_ACCESS_KEY=$(cat /tmp/secrets/AWS_SECRET_ACCESS_KEY)
AWS_DEFAULT_REGION=$(cat /tmp/secrets/AWS_DEFAULT_REGION)
AWS_S3_BUCKET=$(cat /tmp/secrets/AWS_S3_BUCKET)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_S3_BUCKET
echo "[SUCCESS] ✅ AWS credentials loaded successfully"

export PULUMI_K8S_DELETE_UNREACHABLE=true
  echo "[INFO] ⚙️ Environment variable PULUMI_K8S_DELETE_UNREACHABLE set to true"

echo "[INFO] 📋 Reading S3 top-level folders from ${SHARED_DIR}/s3_top_level_folders.txt..."

# Check if input file exists
if [ ! -f "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "[ERROR] ❌ Input file ${SHARED_DIR}/s3_top_level_folders.txt does not exist"
  exit 1
fi

# Check if input file is empty
if [ ! -s "${SHARED_DIR}/s3_top_level_folders.txt" ]; then
  echo "[WARN] ⚠️ Input file ${SHARED_DIR}/s3_top_level_folders.txt is empty"
  echo "[INFO] 🫙 No MAPT folders to process"
  exit 0
fi

mapfile -t CORRELATE_MAPT_ARRAY < "${SHARED_DIR}/s3_top_level_folders.txt"

total=${#CORRELATE_MAPT_ARRAY[@]}
current=0
success_count=0
failed_count=0
echo "[INFO] 📋 Found ${total} S3 top-level folders to process"

# Create files to track results
SUCCESSFUL_DESTROYS="${ARTIFACT_DIR}/successful_destroys.txt"
FAILED_DESTROYS="${ARTIFACT_DIR}/failed_destroys.txt"
touch "${SUCCESSFUL_DESTROYS}"
touch "${FAILED_DESTROYS}"

# Temporarily disable exit on error to capture failures
set +e

for S3_TOP_LEVEL_FOLDER in "${CORRELATE_MAPT_ARRAY[@]}"; do
  current=$((current + 1))
  echo "[INFO] 📋 Processing MAPT: ${S3_TOP_LEVEL_FOLDER} ($current/$total)"

  [ -z "$S3_TOP_LEVEL_FOLDER" ] && echo "[WARN] ⚠️ Skipping empty folder name" && continue

  echo "[INFO] 🗑️ Destroying MAPT for folder: ${S3_TOP_LEVEL_FOLDER}"
  
  # Capture both stdout and stderr to check for errors
  output=$(mapt aws eks destroy \
      --project-name "eks" \
      --backed-url "s3://${AWS_S3_BUCKET}/${S3_TOP_LEVEL_FOLDER}" 2>&1)
  exit_code=$?
  
  # Check for both exit code and error patterns in output
  if [ $exit_code -eq 0 ] && ! echo "$output" | grep -qiE "(stderr|error|failed|exit status [1-9])"; then
    echo "$output"
    echo "[SUCCESS] ✅ Successfully destroyed MAPT: ${S3_TOP_LEVEL_FOLDER}"
    echo "${S3_TOP_LEVEL_FOLDER}" >> "${SUCCESSFUL_DESTROYS}"
    success_count=$((success_count + 1))
  else
    echo "$output"
    echo "[ERROR] ❌ Failed to destroy MAPT: ${S3_TOP_LEVEL_FOLDER}"
    echo "${S3_TOP_LEVEL_FOLDER}" >> "${FAILED_DESTROYS}"
    failed_count=$((failed_count + 1))
  fi
done

# Re-enable exit on error
set -e

echo "[INFO] 📊 Destroy Summary"
echo "[INFO]Total processed: ${total}"
echo "[INFO]Successful: ${success_count}"
echo "[INFO]Failed: ${failed_count}"

# Batch delete successfully destroyed folders from S3
if [ "${success_count}" -gt 0 ]; then
  echo "[INFO] 🗑️ Deleting ${success_count} successfully destroyed folders from S3 bucket..."

  while IFS= read -r folder; do
    if [ -n "$folder" ]; then
      echo "[INFO] 🗑️ Deleting s3://${AWS_S3_BUCKET}/${folder}/..."
      aws s3 rm "s3://${AWS_S3_BUCKET}/${folder}/" --recursive
    fi
  done < "${SUCCESSFUL_DESTROYS}"

  echo "[SUCCESS] ✅ Successfully deleted all folders from S3"
else
  echo "[INFO] 🫙 No folders to delete from S3"
fi

echo "[SUCCESS] ✅ Finished processing all ${total} MAPT folders"

# Exit with failure if any destroys failed
if [ "${failed_count}" -gt 0 ]; then
  echo "[WARN] ⚠️ Exiting with failure due to ${failed_count} failed destroy(s)"
  exit 1
fi

echo "[SUCCESS] ✅ All operations completed successfully"