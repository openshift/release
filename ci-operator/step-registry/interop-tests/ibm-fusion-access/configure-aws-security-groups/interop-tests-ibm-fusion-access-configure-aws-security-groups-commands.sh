#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔒 Configuring AWS security groups for IBM Storage Scale..."
echo "Approach: Modify existing worker security group (matching aws-ibm-gpfs-playground playbook)"

# Set up AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Set up AWS region
REGION="${LEASED_RESOURCE}"
export REGION

echo "AWS credentials file: ${AWS_SHARED_CREDENTIALS_FILE}"
echo "AWS region: ${REGION}"

# Get cluster information
CLUSTER_NAME="fusion-access-test"
INFRA_ID=""

# Try to get cluster name from shared directory
if [[ -f "${SHARED_DIR}/CLUSTER_NAME" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
fi

# Get infrastructure ID from metadata.json
if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
  INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
  echo "Infrastructure ID: ${INFRA_ID}"
else
  echo "ERROR: metadata.json not found"
  exit 1
fi

echo "Cluster name: ${CLUSTER_NAME}"

# Gather security group info for workers (matching playbook approach)
# See: https://www.ibm.com/docs/en/scalecontainernative/5.2.2?topic=aws-red-hat-openshift-configuration
echo ""
echo "Step 1: Finding worker security group..."
echo "Searching for security groups with tags:"
echo "  - sigs.k8s.io/cluster-api-provider-aws/role: node"
echo "  - Name: ${INFRA_ID}-*"

# Find the worker security group
WORKER_SG_JSON=$(aws ec2 describe-security-groups \
  --region "${REGION}" \
  --filters \
    "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node" \
    "Name=tag:Name,Values=${INFRA_ID}-*" \
  --query 'SecurityGroups[0]' \
  --output json \
  --no-cli-pager)

if [[ -z "${WORKER_SG_JSON}" ]] || [[ "${WORKER_SG_JSON}" == "null" ]]; then
  echo "ERROR: Could not find worker security group"
  echo "Searched for tags: sigs.k8s.io/cluster-api-provider-aws/role=node, Name=${INFRA_ID}-*"
  exit 1
fi

# Extract security group details
WORKER_SG_ID=$(echo "${WORKER_SG_JSON}" | jq -r '.GroupId')
WORKER_SG_NAME=$(echo "${WORKER_SG_JSON}" | jq -r '.GroupName')
WORKER_SG_DESC=$(echo "${WORKER_SG_JSON}" | jq -r '.Description')

if [[ -z "${WORKER_SG_ID}" ]] || [[ "${WORKER_SG_ID}" == "null" ]]; then
  echo "ERROR: Failed to extract worker security group ID"
  exit 1
fi

echo "✅ Found worker security group:"
echo "  ID: ${WORKER_SG_ID}"
echo "  Name: ${WORKER_SG_NAME}"
echo "  Description: ${WORKER_SG_DESC}"

# Save security group ID for other steps
echo "${WORKER_SG_ID}" > "${SHARED_DIR}/worker_sg_id"
echo "Security group ID saved to: ${SHARED_DIR}/worker_sg_id"

# Add IBM Storage Scale ports to the worker security group
# Matching playbook: https://raw.githubusercontent.com/openshift-storage-scale/aws-ibm-gpfs-playground/6e712d7c8261d5330ab74b1aa4a60f5279a38298/playbooks/install.yml
echo ""
echo "Step 2: Adding IBM Storage Scale ports to worker security group..."
echo "Required ports:"
echo "  - TCP 1191: GPFS admin communication"
echo "  - TCP 12345: GPFS daemon communication"
echo "  - TCP 60000-61000: TSC command port range"

# Function to add ingress rule with retry
add_ingress_rule() {
  local port_spec=$1
  local description=$2
  
  echo "Adding rule: ${description} (${port_spec})"
  
  if aws ec2 authorize-security-group-ingress \
    --region "${REGION}" \
    --group-id "${WORKER_SG_ID}" \
    --protocol tcp \
    --port "${port_spec}" \
    --source-group "${WORKER_SG_ID}" \
    --group-owner "$(aws sts get-caller-identity --query Account --output text --no-cli-pager)" \
    --no-cli-pager 2>&1; then
    echo "  ✅ Added: ${description}"
    return 0
  else
    # Check if rule already exists
    if aws ec2 describe-security-group-rules \
      --region "${REGION}" \
      --filters "Name=group-id,Values=${WORKER_SG_ID}" \
      --query "SecurityGroupRules[?ToPort==\`${port_spec%%[-:]*}\` && IpProtocol=='tcp']" \
      --output text \
      --no-cli-pager | grep -q "${WORKER_SG_ID}"; then
      echo "  ℹ️  Rule already exists: ${description}"
      return 0
    else
      echo "  ❌ Failed to add: ${description}"
      return 1
    fi
  fi
}

# Add GPFS admin port (1191)
add_ingress_rule "1191" "GPFS admin communication"

# Add GPFS daemon port (12345)
add_ingress_rule "12345" "GPFS daemon communication"

# Add TSC command port range (60000-61000)
add_ingress_rule "60000-61000" "TSC command port range"

echo ""
echo "✅ Security group configuration completed successfully!"
echo ""
echo "Summary:"
echo "  Worker Security Group ID: ${WORKER_SG_ID}"
echo "  Worker Security Group Name: ${WORKER_SG_NAME}"
echo "  Region: ${REGION}"
echo "  Infrastructure ID: ${INFRA_ID}"
echo ""
echo "Added rules for IBM Storage Scale:"
echo "  ✅ TCP 1191 (GPFS admin)"
echo "  ✅ TCP 12345 (GPFS daemon)"
echo "  ✅ TCP 60000-61000 (TSC commands)"
echo ""
echo "All traffic between worker nodes on these ports is now allowed."
