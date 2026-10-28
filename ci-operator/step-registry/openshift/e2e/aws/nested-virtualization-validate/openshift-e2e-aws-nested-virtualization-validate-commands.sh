#!/bin/bash

# Validate that AWS compute nodes have nested virtualization enabled
#
# This script reads EC2 instance information and verifies that all compute
# nodes have CpuOptions.NestedVirtualization set to "Enabled"

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Validating Nested Virtualization"
echo "========================================="

INSTANCES_FILE="${ARTIFACT_DIR}/aws-resources/ec2-instances.json"

# Check if the instances file exists
if [[ ! -f "${INSTANCES_FILE}" ]]; then
  echo "ERROR: EC2 instances file not found at: ${INSTANCES_FILE}"
  echo "Make sure the ipi-install-aws-verify-resources step ran before this validation step."
  exit 1
fi

echo "Reading EC2 instance information from: ${INSTANCES_FILE}"
echo ""

# Get compute/worker nodes (filter out control plane/master nodes)
COMPUTE_INSTANCES=$(jq -r '
  .Reservations[].Instances[] |
  select(.Tags[]? | select(.Key == "Name" and (.Value | contains("worker") or contains("compute"))))
' "${INSTANCES_FILE}")

if [[ -z "${COMPUTE_INSTANCES}" ]]; then
  echo "WARNING: No compute/worker nodes found. Checking all instances..."
  COMPUTE_INSTANCES=$(jq -r '.Reservations[].Instances[]' "${INSTANCES_FILE}")
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
echo "========================================="
echo "Validation Summary"
echo "========================================="
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
