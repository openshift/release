#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: '🔒 Configuring AWS security groups for IBM Storage Scale...'
: 'Approach: Modify existing worker security group (matching aws-ibm-gpfs-playground playbook)'

# Set up AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Set up AWS region
region="${LEASED_RESOURCE}"
export region

: "AWS credentials file: ${AWS_SHARED_CREDENTIALS_FILE}"
: "AWS region: ${region}"

# Get cluster information
clusterName="fusion-access-test"
infraId=""

# Try to get cluster name from shared directory
if [[ -f "${SHARED_DIR}/CLUSTER_NAME" ]]; then
  clusterName="$(<"${SHARED_DIR}/CLUSTER_NAME")"
fi

# Get infrastructure ID from metadata.json
if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
  infraId=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
  : "Infrastructure ID: ${infraId}"
else
  : 'ERROR: metadata.json not found'
  exit 1
fi

: "Cluster name: ${clusterName}"

# Gather security group info for workers (matching playbook approach)
# See: https://www.ibm.com/docs/en/scalecontainernative/5.2.2?topic=aws-red-hat-openshift-configuration
: 'Step 1: Finding worker security group...'
: 'Searching for security groups with tags:'
: '  - sigs.k8s.io/cluster-api-provider-aws/role: node'
: "  - Name: ${infraId}-*"

# Find the worker security group
workerSgJson=$(aws ec2 describe-security-groups \
  --region "${region}" \
  --filters \
    "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node" \
    "Name=tag:Name,Values=${infraId}-*" \
  --query 'SecurityGroups[0]' \
  --output json \
  --no-cli-pager)

if [[ -z "${workerSgJson}" ]] || [[ "${workerSgJson}" == "null" ]]; then
  : 'ERROR: Could not find worker security group'
  : "Searched for tags: sigs.k8s.io/cluster-api-provider-aws/role=node, Name=${infraId}-*"
  exit 1
fi

# Extract security group details
workerSgId=$(echo "${workerSgJson}" | jq -r '.GroupId')
workerSgName=$(echo "${workerSgJson}" | jq -r '.GroupName')
workerSgDesc=$(echo "${workerSgJson}" | jq -r '.Description')

if [[ -z "${workerSgId}" ]] || [[ "${workerSgId}" == "null" ]]; then
  : 'ERROR: Failed to extract worker security group ID'
  exit 1
fi

: '✅ Found worker security group:'
: "  ID: ${workerSgId}"
: "  Name: ${workerSgName}"
: "  Description: ${workerSgDesc}"

# Save security group ID for other steps
echo "${workerSgId}" > "${SHARED_DIR}/worker_sg_id"
: "Security group ID saved to: ${SHARED_DIR}/worker_sg_id"

# Add IBM Storage Scale ports to the worker security group
# Matching playbook: https://raw.githubusercontent.com/openshift-storage-scale/aws-ibm-gpfs-playground/6e712d7c8261d5330ab74b1aa4a60f5279a38298/playbooks/install.yml
: 'Step 2: Adding IBM Storage Scale ports to worker security group...'
: 'Required ports:'
: '  - TCP 1191: GPFS admin communication'
: '  - TCP 12345: GPFS daemon communication'
: '  - TCP 60000-61000: TSC command port range'

# Function to add ingress rule with retry
AddIngressRule() {
  local portSpec=$1
  local description=$2
  
  : "Adding rule: ${description} (${portSpec})"
  
  if aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${workerSgId}" \
    --protocol tcp \
    --port "${portSpec}" \
    --source-group "${workerSgId}" \
    --group-owner "$(aws sts get-caller-identity --query Account --output text --no-cli-pager)" \
    --no-cli-pager; then
    : "  ✅ Added: ${description}"
    return 0
  else
    # Check if rule already exists
    if aws ec2 describe-security-group-rules \
      --region "${region}" \
      --filters "Name=group-id,Values=${workerSgId}" \
      --query "SecurityGroupRules[?ToPort==\`${portSpec%%[-:]*}\` && IpProtocol=='tcp']" \
      --output text \
      --no-cli-pager | grep -q "${workerSgId}"; then
      : "  ℹ️  Rule already exists: ${description}"
      return 0
    else
      : "  ❌ Failed to add: ${description}"
      return 1
    fi
  fi
}

# Add GPFS admin port (1191)
AddIngressRule "1191" "GPFS admin communication"

# Add GPFS daemon port (12345)
AddIngressRule "12345" "GPFS daemon communication"

# Add TSC command port range (60000-61000)
AddIngressRule "60000-61000" "TSC command port range"

: '✅ Security group configuration completed successfully!'
: 'Summary:'
: "  Worker Security Group ID: ${workerSgId}"
: "  Worker Security Group Name: ${workerSgName}"
: "  Region: ${region}"
: "  Infrastructure ID: ${infraId}"
: 'Added rules for IBM Storage Scale:'
: '  ✅ TCP 1191 (GPFS admin)'
: '  ✅ TCP 12345 (GPFS daemon)'
: '  ✅ TCP 60000-61000 (TSC commands)'
: 'All traffic between worker nodes on these ports is now allowed.'

