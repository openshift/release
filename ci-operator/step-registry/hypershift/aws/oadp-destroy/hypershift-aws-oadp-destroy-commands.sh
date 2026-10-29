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

aws s3 rb "s3://${BUCKET_NAME}" --force --region "${REGION}" 2>/dev/null || true

# Verify bucket was deleted to avoid resource leaks
if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
    echo "WARNING: Bucket ${BUCKET_NAME} still exists after initial cleanup, retrying..."
    sleep 10
    aws s3 rb "s3://${BUCKET_NAME}" --force --region "${REGION}" 2>/dev/null || true
    if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
        echo "ERROR: Failed to delete bucket ${BUCKET_NAME} - manual cleanup may be required"
        exit 1
    else
        echo "Bucket ${BUCKET_NAME} successfully deleted on retry"
    fi
fi

echo "S3 bucket cleanup done"
