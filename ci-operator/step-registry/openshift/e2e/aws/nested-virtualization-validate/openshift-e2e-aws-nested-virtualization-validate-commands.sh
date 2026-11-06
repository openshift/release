#!/bin/bash

# Validate that AWS compute nodes have nested virtualization enabled
#
# This script queries EC2 directly and verifies that all compute
# nodes have CpuOptions.NestedVirtualization set to "Enabled"

set -o nounset
set -o errexit
set -o pipefail

echo "Validating Nested Virtualization on AWS EC2 Instances"

# Set up AWS credentials from the cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Determine the AWS region - read from install-config.yaml to ensure we query the correct region
# This handles cases where AWS_REGION_OVERWRITE was used during installation
if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
  AWS_REGION=$(yq-go r "${SHARED_DIR}/install-config.yaml" 'platform.aws.region')
else
  echo "WARNING: install-config.yaml not found, falling back to LEASED_RESOURCE"
  AWS_REGION="${LEASED_RESOURCE}"
fi

if [[ -z "${AWS_REGION}" || "${AWS_REGION}" == "null" ]]; then
  echo "ERROR: Could not determine AWS region"
  exit 1
fi

export AWS_DEFAULT_REGION="${AWS_REGION}"
echo "AWS Region: ${AWS_REGION}"

# Get the cluster infrastructure name to filter instances
INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")

if [[ -z "${INFRA_ID}" || "${INFRA_ID}" == "null" ]]; then
  echo "ERROR: Could not determine cluster infrastructure ID from metadata.json"
  exit 1
fi

echo "Cluster Infrastructure ID: ${INFRA_ID}"
echo "Querying EC2 instances with tag kubernetes.io/cluster/${INFRA_ID}=owned"
echo ""

# Query EC2 for instances belonging to this cluster
INSTANCES_JSON=$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --query 'Reservations[].Instances[]' \
  --output json)

# Get compute/worker nodes (filter out control plane/master nodes)
COMPUTE_INSTANCES=$(echo "${INSTANCES_JSON}" | jq -r '
  .[] |
  select(.Tags[]? | select(.Key == "Name" and (.Value | contains("worker") or contains("compute"))))
')

if [[ -z "${COMPUTE_INSTANCES}" ]]; then
  echo "WARNING: No compute/worker nodes found. Checking all cluster instances..."
  COMPUTE_INSTANCES=$(echo "${INSTANCES_JSON}" | jq -r '.[]')
fi

# Count total instances to validate
INSTANCE_COUNT=$(echo "${COMPUTE_INSTANCES}" | jq -s 'length')

if [[ "${INSTANCE_COUNT}" -eq 0 ]]; then
  echo "ERROR: No instances found to validate"
  exit 1
fi

echo "Found ${INSTANCE_COUNT} instance(s) to validate"
echo ""

# Track validation results
PASS_COUNT=0
FAIL_COUNT=0
FAILED_INSTANCES=""

# Validate each instance
while IFS= read -r instance; do
  INSTANCE_ID=$(echo "${instance}" | jq -r '.InstanceId')
  INSTANCE_TYPE=$(echo "${instance}" | jq -r '.InstanceType')
  INSTANCE_NAME=$(echo "${instance}" | jq -r '(.Tags[] | select(.Key == "Name") | .Value) // "N/A"')
  NESTED_VIRT=$(echo "${instance}" | jq -r '.CpuOptions.NestedVirtualization // "N/A"')

  echo "Checking instance: ${INSTANCE_ID} (${INSTANCE_NAME})"
  echo "  Instance Type: ${INSTANCE_TYPE}"
  echo "  Nested Virtualization: ${NESTED_VIRT}"

  if [[ "${NESTED_VIRT}" == "Enabled" ]]; then
    echo "  ✓ PASS: Nested virtualization is enabled"
    ((PASS_COUNT++)) || true
  else
    echo "  ✗ FAIL: Nested virtualization is NOT enabled (value: ${NESTED_VIRT})"
    ((FAIL_COUNT++)) || true
    FAILED_INSTANCES="${FAILED_INSTANCES}${INSTANCE_ID} (${INSTANCE_NAME})\n"
  fi
  echo ""
done < <(echo "${COMPUTE_INSTANCES}" | jq -c '.')

# Print summary
echo "Validation Summary"
echo "Total instances checked: ${INSTANCE_COUNT}"
echo "Passed: ${PASS_COUNT}"
echo "Failed: ${FAIL_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "FAILED INSTANCES:"
  echo -e "${FAILED_INSTANCES}"
  echo ""
  echo "ERROR: Nested virtualization validation failed for ${FAIL_COUNT} instance(s)"
  exit 1
fi

echo "SUCCESS: All compute nodes have nested virtualization enabled"
