#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== Discovering AWS Windows Server AMI ==="

# Get AWS region from install-config or cluster
if [[ -f "${SHARED_DIR}/AWS_REGION" ]]; then
    AWS_REGION=$(cat "${SHARED_DIR}/AWS_REGION")
elif [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
    AWS_REGION=$(yq-go r "${SHARED_DIR}/install-config.yaml" 'platform.aws.region')
else
    echo "ERROR: Cannot determine AWS region"
    exit 1
fi

echo "AWS Region: ${AWS_REGION}"

# Export AWS region to SHARED_DIR for windows-byoh-provision step
echo "${AWS_REGION}" > "${SHARED_DIR}/AWS_REGION"
echo "Exported AWS_REGION to ${SHARED_DIR}/AWS_REGION"

# Configure AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION

# Determine Windows version
WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2022}"
echo "Windows Server version: ${WINDOWS_VERSION}"

# Query AWS for latest Windows Server AMI
echo "Querying AWS for latest Windows Server ${WINDOWS_VERSION} AMI..."

AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=Windows_Server-${WINDOWS_VERSION}-English-Full-Base-*" \
              "Name=state,Values=available" \
    --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
    --output text \
    --region "${AWS_REGION}")

if [[ -z "${AMI_ID}" ]] || [[ "${AMI_ID}" == "None" ]]; then
    echo "ERROR: Failed to discover Windows Server ${WINDOWS_VERSION} AMI in region ${AWS_REGION}"
    echo "Attempting to list available Windows images..."
    aws ec2 describe-images \
        --owners amazon \
        --filters "Name=name,Values=Windows_Server-${WINDOWS_VERSION}*" \
                  "Name=state,Values=available" \
        --query "Images[*].[Name,ImageId,CreationDate]" \
        --output table \
        --region "${AWS_REGION}" || true
    exit 1
fi

echo "Discovered Windows AMI: ${AMI_ID}"

# Export to SHARED_DIR for windows-byoh-provision step
echo "${AMI_ID}" > "${SHARED_DIR}/AWS_WINDOWS_AMI"
echo "Exported AWS_WINDOWS_AMI to ${SHARED_DIR}/AWS_WINDOWS_AMI"

echo "=== Windows AMI Discovery Complete ==="
