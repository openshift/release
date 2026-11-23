#!/bin/bash

# Validate that AWS compute nodes have nested virtualization enabled
#
# This script queries EC2 directly and verifies that all compute
# nodes have CpuOptions.NestedVirtualization set to "Enabled"

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

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
echo ""

# Query AWS EC2 directly for instances belonging to this cluster
echo "Querying AWS for cluster instances..."
INSTANCES_JSON=$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --output json | jq '[.Reservations[].Instances[]]')

# Get compute/worker nodes
COMPUTE_INSTANCES=$(echo "${INSTANCES_JSON}" | jq -r '
  .[] |
  select(.Tags[]? | select(.Key == "Name" and (.Value | contains("-worker-") or contains("-compute-"))))
')

# Get control plane/master nodes
CONTROL_INSTANCES=$(echo "${INSTANCES_JSON}" | jq -r '
  .[] |
  select(.Tags[]? | select(.Key == "Name" and (.Value | contains("-master-") or contains("-controlplane-"))))
')

if [[ -z "${COMPUTE_INSTANCES}" ]]; then
  printf "ERROR: No compute/worker nodes found"

  COMPUTE_REPLICAS="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'compute[0].replicas')"
  if [[ "${COMPUTE_REPLICAS}" != "0" ]]; then
    echo ""
    exit 1
  fi
  echo ", but this is expected because Compute Replicas is set to 0"
fi

# Count total instances to validate
COMPUTE_INSTANCE_COUNT=$(echo "${COMPUTE_INSTANCES}" | jq -s 'length')
CONTROL_INSTANCE_COUNT=$(echo "${CONTROL_INSTANCES}" | jq -s 'length')
INSTANCE_COUNT=$((COMPUTE_INSTANCE_COUNT + CONTROL_INSTANCE_COUNT))

if [[ "${INSTANCE_COUNT}" -eq 0 ]]; then
  echo "ERROR: No instances found to validate"
  exit 1
fi

echo "Found ${INSTANCE_COUNT} instance(s) to validate"
echo ""

# Track validation results
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_INSTANCES=""

COMPUTE_NESTED_VIRT_REQUEST="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'compute[0].platform.aws.cpuOptions.nestedVirtualization')"
COMPUTE_NESTED_VIRT_REQUEST="${COMPUTE_NESTED_VIRT_REQUEST:-N/A}"
CONTROL_NESTED_VIRT_REQUEST="$(yq-go r "${SHARED_DIR}/install-config.yaml" 'controlPlane.platform.aws.cpuOptions.nestedVirtualization')"
CONTROL_NESTED_VIRT_REQUEST="${CONTROL_NESTED_VIRT_REQUEST:-N/A}"

# Validate each compute instance
while IFS= read -r instance; do
  INSTANCE_ID=$(echo "${instance}" | jq -r '.InstanceId')
  INSTANCE_TYPE=$(echo "${instance}" | jq -r '.InstanceType')
  INSTANCE_NAME=$(echo "${instance}" | jq -r '(.Tags[] | select(.Key == "Name") | .Value) // "N/A"')
  NESTED_VIRT=$(echo "${instance}" | jq -r '.CpuOptions.NestedVirtualization // "N/A"')

  echo "Checking instance: ${INSTANCE_ID} (${INSTANCE_NAME})"
  echo "  Instance Type: ${INSTANCE_TYPE}"
  echo "  Nested Virtualization: ${NESTED_VIRT}"

  if [[ "${NESTED_VIRT^^}" == "${COMPUTE_NESTED_VIRT_REQUEST^^}" ]]; then
    echo "  ✓ PASS: Nested virtualization is set to the expected value"
    ((PASS_COUNT++)) || true
  else
    echo "  ✗ FAIL: Nested virtualization is NOT set to the expected value [${COMPUTE_NESTED_VIRT_REQUEST}]"
    ((FAIL_COUNT++)) || true
    FAILED_INSTANCES="${FAILED_INSTANCES}${INSTANCE_ID} (${INSTANCE_NAME})\n"
    CPU_OPTIONS=$(echo "${instance}" | jq -r '.CpuOptions.NestedVirtualization // "N/A"')
    echo "  CPU Options: ${CPU_OPTIONS}"
  fi
  echo ""
done < <(echo "${COMPUTE_INSTANCES}" | jq -c '.')

# Validate each control plane instance
while IFS= read -r instance; do
  INSTANCE_ID=$(echo "${instance}" | jq -r '.InstanceId')
  INSTANCE_TYPE=$(echo "${instance}" | jq -r '.InstanceType')
  INSTANCE_NAME=$(echo "${instance}" | jq -r '(.Tags[] | select(.Key == "Name") | .Value) // "N/A"')
  NESTED_VIRT=$(echo "${instance}" | jq -r '.CpuOptions.NestedVirtualization // "N/A"')

  echo "Checking instance: ${INSTANCE_ID} (${INSTANCE_NAME})"
  echo "  Instance Type: ${INSTANCE_TYPE}"
  echo "  Nested Virtualization: ${NESTED_VIRT}"

  if [[ "${NESTED_VIRT^^}" == "${CONTROL_NESTED_VIRT_REQUEST^^}" ]]; then
    echo "  ✓ PASS: Nested virtualization is set to the expected value"
    ((PASS_COUNT++)) || true
  elif [[ "${CONTROL_NESTED_VIRT_REQUEST^^}" == "N/A" ]]; then
    echo "  - SKIP: No nested virtualization requirement for control plane"
    ((SKIP_COUNT++)) || true
    continue
  else
    echo "  ✗ FAIL: Nested virtualization is NOT set to the expected value [${CONTROL_NESTED_VIRT_REQUEST}]"
    ((FAIL_COUNT++)) || true
    FAILED_INSTANCES="${FAILED_INSTANCES}${INSTANCE_ID} (${INSTANCE_NAME})\n"
    CPU_OPTIONS=$(echo "${instance}" | jq -r '.CpuOptions.NestedVirtualization // "N/A"')
    echo "  CPU Options: ${CPU_OPTIONS}"
  fi
  echo ""
done < <(echo "${CONTROL_INSTANCES}" | jq -c '.')

# Print summary
echo ""
echo "Validation Summary"
echo "Total instances checked: ${INSTANCE_COUNT}"
echo "Passed: ${PASS_COUNT}"
echo "Failed: ${FAIL_COUNT}"
echo "Skipped: ${SKIP_COUNT}"
echo ""

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo "FAILED INSTANCES:"
  echo -e "${FAILED_INSTANCES}"
  echo ""
  echo "ERROR: Nested virtualization validation failed for ${FAIL_COUNT} instance(s)"
  exit 1
fi

echo "SUCCESS: All compute nodes have nested virtualization enabled"
