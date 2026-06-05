#!/bin/bash

set -exuo pipefail

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

HC_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

INFRA_ID="$(cat ${SHARED_DIR}/infra-id)"
INFRA_JSON="${SHARED_DIR}/aws_infra_output.json"

# Verify infrastructure output file exists
if [[ ! -f "${INFRA_JSON}" ]]; then
  echo "ERROR: Infrastructure output file not found at ${INFRA_JSON}"
  echo "The hypershift-aws-create-infra step must run before this step"
  exit 1
fi

# Extract zone IDs from infrastructure output
PUBLIC_ZONE_ID="$(jq -r '.publicZoneID' ${INFRA_JSON})"
PRIVATE_ZONE_ID="$(jq -r '.privateZoneID' ${INFRA_JSON})"
LOCAL_ZONE_ID="$(jq -r '.localZoneID // ""' ${INFRA_JSON})"

echo "$(date) Creating AWS IAM resources for infrastructure ${INFRA_ID}"
echo "Region: ${HC_REGION}"
echo "Public Zone ID: ${PUBLIC_ZONE_ID}"
echo "Private Zone ID: ${PRIVATE_ZONE_ID}"
[[ -n "${LOCAL_ZONE_ID}" ]] && echo "Local Zone ID: ${LOCAL_ZONE_ID}"

# Build hypershift create iam command
IAM_COMMAND=(
  /usr/bin/hypershift create iam aws
  --infra-id "${INFRA_ID}"
  --aws-creds="${AWS_GUEST_INFRA_CREDENTIALS_FILE}"
  --oidc-storage-provider-s3-bucket-name=hypershift-ci-oidc
  --oidc-storage-provider-s3-region=us-east-1
  --region "${HC_REGION}"
  --public-zone-id "${PUBLIC_ZONE_ID}"
  --private-zone-id "${PRIVATE_ZONE_ID}"
  --output-file "${SHARED_DIR}/aws_iam_output.json"
)

# Add local zone ID if it exists (for private clusters)
if [[ -n "${LOCAL_ZONE_ID}" ]]; then
  IAM_COMMAND+=(--local-zone-id "${LOCAL_ZONE_ID}")
fi

# Create IAM resources
"${IAM_COMMAND[@]}"

echo "$(date) AWS IAM resources created successfully"
echo "IAM resources saved to ${SHARED_DIR}/aws_iam_output.json"

# Display created IAM resources (for debugging)
if [[ -f "${SHARED_DIR}/aws_iam_output.json" ]]; then
  echo "Created IAM resources:"
  cat "${SHARED_DIR}/aws_iam_output.json"
fi
