#!/bin/bash

set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

region="${LEASED_RESOURCE:?LEASED_RESOURCE must contain the AWS lease region}"
bucket="quay-pr-smoke-${BUILD_ID:?BUILD_ID is required}"
bucket="$(tr '[:upper:]_' '[:lower:]-' <<<"${bucket}")"

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${region}"
AWS_ACCESS_KEY_ID="$(< /var/run/quay-qe-aws-secret/access_key)"
AWS_SECRET_ACCESS_KEY="$(< /var/run/quay-qe-aws-secret/secret_key)"

echo "Creating ephemeral S3 bucket ${bucket} in ${region}"
create_args=(--bucket "${bucket}" --region "${region}")
if [[ "${region}" != "us-east-1" ]]; then
  create_args+=(--create-bucket-configuration "LocationConstraint=${region}")
fi
aws s3api create-bucket "${create_args[@]}" >/dev/null

# Write cleanup metadata immediately after creation. No credentials are stored.
printf '%s\n' "${bucket}" >"${SHARED_DIR}/quay-pr-smoke-s3-bucket"
printf '%s\n' "${region}" >"${SHARED_DIR}/quay-pr-smoke-s3-region"

aws s3api put-public-access-block \
  --bucket "${bucket}" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
aws s3api put-bucket-encryption \
  --bucket "${bucket}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

jq -n --arg bucket "${bucket}" --arg region "${region}" \
  '{provider:"aws-s3", bucket:$bucket, region:$region, ephemeral:true}' \
  >"${ARTIFACT_DIR}/s3-provisioning.json"

echo "S3 bucket is ready"
