#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔒 Starting AWS security group configuration..."

# Set up AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Set up AWS region
REGION="${LEASED_RESOURCE}"
export REGION

echo "AWS credentials file: ${AWS_SHARED_CREDENTIALS_FILE}"
echo "AWS region: ${REGION}"

# Get cluster information
CLUSTER_NAME="fusion-access-test"
VPC_ID=""

# Try to get cluster name from shared directory
if [[ -f "${SHARED_DIR}/CLUSTER_NAME" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
fi

# Try to get VPC ID from shared directory
if [[ -f "${SHARED_DIR}/vpc_id" ]]; then
  VPC_ID="$(<"${SHARED_DIR}/vpc_id")"
else
  # Discover VPC ID using infra_id from metadata.json (like bastion host step)
  if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
    infra_id=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
    vpc_name="${infra_id}-vpc"
    echo "Looking up VPC with name: ${vpc_name}"
    VPC_ID=$(aws --region "${REGION}" ec2 describe-vpcs --filters "Name=tag:Name,Values=${vpc_name}" --query 'Vpcs[0].VpcId' --output text --no-cli-pager)
    if [[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]]; then
      echo "WARNING: Could not find VPC with name ${vpc_name}, trying default VPC"
      VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text --no-cli-pager)
    fi
  else
    echo "WARNING: No metadata.json found, trying default VPC"
    VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text --no-cli-pager)
  fi
fi

echo "Cluster name: ${CLUSTER_NAME}"
echo "VPC ID: ${VPC_ID}"

# Create a custom security group for IBM Storage Scale
SG_NAME="${CLUSTER_NAME}-ibm-storage-scale-sg"
echo "Creating custom security group: ${SG_NAME}"

# Create tag specifications file
TAG_JSON=$(mktemp)
cat > "${TAG_JSON}" <<EOF
[
  {
    "ResourceType": "security-group",
    "Tags": [
      {
        "Key": "Name",
        "Value": "${SG_NAME}"
      },
      {
        "Key": "Purpose",
        "Value": "IBM-Storage-Scale"
      }
    ]
  }
]
EOF

# Debug: Show the values being used
echo "Debug information:"
echo "  SG_NAME: '${SG_NAME}'"
echo "  VPC_ID: '${VPC_ID}'"
echo "  REGION: '${REGION}'"
echo "  TAG_JSON: '${TAG_JSON}'"

# Create the security group
echo "Creating security group with command:"
echo "aws ec2 create-security-group --region \"${REGION}\" --group-name \"${SG_NAME}\" --vpc-id \"${VPC_ID}\" --description \"IBM Storage Scale security group for Fusion Access Operator testing\" --tag-specifications \"file://${TAG_JSON}\" --query 'GroupId' --output text"

SG_ID=$(aws ec2 create-security-group --region "${REGION}" --group-name "${SG_NAME}" --vpc-id "${VPC_ID}" --description "IBM Storage Scale security group for Fusion Access Operator testing" --tag-specifications "file://${TAG_JSON}" --query 'GroupId' --output text --no-cli-pager 2>&1)
SG_CREATE_EXIT_CODE=$?

# Clean up temporary file
rm -f "${TAG_JSON}"

if [[ $SG_CREATE_EXIT_CODE -ne 0 ]]; then
  echo "ERROR: Failed to create security group"
  echo "Exit code: $SG_CREATE_EXIT_CODE"
  echo "Output: $SG_ID"
  exit 1
fi

if [[ -z "${SG_ID}" ]]; then
  echo "ERROR: Security group creation succeeded but no group ID returned"
  exit 1
fi

echo "Created security group: ${SG_ID}"

# Save security group ID to /tmp
echo "${SG_ID}" > "/tmp/security_groups_ids"
echo "Security group ID saved to: /tmp/security_groups_ids"

# Also export it as an environment variable for other steps
echo "export SECURITY_GROUP_ID=${SG_ID}" >> /tmp/security_group_env
echo "Security group ID also exported to: /tmp/security_group_env"

echo "Security group configuration completed"
echo "Security group ID: ${SG_ID}"

# Get the VPC CIDR for allowing traffic within the VPC
VPC_CIDR=$(aws ec2 describe-vpcs --region "${REGION}" --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text --no-cli-pager)
echo "VPC CIDR: ${VPC_CIDR}"

# Allow traffic from within the VPC
aws ec2 authorize-security-group-ingress \
  --region "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 0-65535 \
  --cidr "${VPC_CIDR}" \
  --no-cli-pager || echo "WARNING: TCP rule may already exist"

aws ec2 authorize-security-group-ingress \
  --region "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol udp \
  --port 0-65535 \
  --cidr "${VPC_CIDR}" \
  --no-cli-pager || echo "WARNING: UDP rule may already exist"

echo "✅ Security group configuration completed"
echo "Security Group ID: ${SG_ID}"
echo "Security Group Name: ${SG_NAME}"
echo "Region: ${REGION}"
echo "VPC ID: ${VPC_ID}"
