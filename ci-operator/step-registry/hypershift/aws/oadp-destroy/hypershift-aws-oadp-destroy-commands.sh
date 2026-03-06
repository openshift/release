#!/bin/bash

set -euo pipefail

REGION="${OADP_AWS_REGION:-us-east-1}"
export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

if [ ! -f "${SHARED_DIR}/oadp-bucket-name" ]; then
    echo "No oadp-bucket-name file found, skipping S3 bucket cleanup"
    exit 0
fi

BUCKET_NAME=$(cat "${SHARED_DIR}/oadp-bucket-name")
echo "Cleaning up S3 bucket ${BUCKET_NAME}..."

aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "${REGION}" 2>/dev/null || true
aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null || true

echo "S3 bucket cleanup done"
