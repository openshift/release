#!/bin/bash

set -euo pipefail

bucket_file="${SHARED_DIR}/quay-pr-smoke-s3-bucket"
region_file="${SHARED_DIR}/quay-pr-smoke-s3-region"
if [[ ! -s "${bucket_file}" || ! -s "${region_file}" ]]; then
  echo "No S3 bucket metadata was recorded; nothing to delete"
  exit 0
fi

bucket="$(< "${bucket_file}")"
region="$(< "${region_file}")"
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${region}"
AWS_ACCESS_KEY_ID="$(< /var/run/quay-qe-aws-secret/access_key)"
AWS_SECRET_ACCESS_KEY="$(< /var/run/quay-qe-aws-secret/secret_key)"

echo "Emptying and deleting S3 bucket ${bucket} in ${region}"
aws s3 rm "s3://${bucket}" --recursive --only-show-errors
aws s3api delete-bucket --bucket "${bucket}" --region "${region}"

if aws s3api head-bucket --bucket "${bucket}" --region "${region}" 2>/dev/null; then
  echo "S3 bucket ${bucket} still exists after deletion" >&2
  exit 1
fi

echo "Verified deletion of S3 bucket ${bucket}"
