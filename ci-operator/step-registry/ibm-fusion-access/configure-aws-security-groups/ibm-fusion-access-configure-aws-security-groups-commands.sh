#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Configuring AWS security groups for IBM Storage Scale...'
: 'Approach: Modify existing worker security group (matching aws-ibm-gpfs-playground playbook)'

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
export REGION

: "AWS credentials file: ${AWS_SHARED_CREDENTIALS_FILE}"
: "AWS region: ${REGION}"

CLUSTER_NAME="fusion-access-test"
INFRA_ID=""

if [[ -f "${SHARED_DIR}/CLUSTER_NAME" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
fi

if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
  INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
  : "Infrastructure ID: ${INFRA_ID}"
else
  : 'ERROR: metadata.json not found'
  exit 1
fi

: "Cluster name: ${CLUSTER_NAME}"

# See: https://www.ibm.com/docs/en/scalecontainernative/5.2.2?topic=aws-red-hat-openshift-configuration
: 'Step 1: Finding worker security group...'

WORKER_SG_JSON=$(aws ec2 describe-security-groups \
  --region "${REGION}" \
  --filters \
    "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node" \
    "Name=tag:Name,Values=${INFRA_ID}-*" \
  --query 'SecurityGroups[0]' \
  --output json \
  --no-cli-pager)

if [[ -z "${WORKER_SG_JSON}" ]] || [[ "${WORKER_SG_JSON}" == "null" ]]; then
  : 'ERROR: Could not find worker security group'
  : "Searched for tags: sigs.k8s.io/cluster-api-provider-aws/role=node, Name=${INFRA_ID}-*"
  exit 1
fi

WORKER_SG_ID=$(echo "${WORKER_SG_JSON}" | jq -r '.GroupId')
WORKER_SG_NAME=$(echo "${WORKER_SG_JSON}" | jq -r '.GroupName')
WORKER_SG_DESC=$(echo "${WORKER_SG_JSON}" | jq -r '.Description')

if [[ -z "${WORKER_SG_ID}" ]] || [[ "${WORKER_SG_ID}" == "null" ]]; then
  : 'ERROR: Failed to extract worker security group ID'
  exit 1
fi

: 'Found worker security group:'
: "  ID: ${WORKER_SG_ID}"
: "  Name: ${WORKER_SG_NAME}"
: "  Description: ${WORKER_SG_DESC}"

echo "${WORKER_SG_ID}" > "${SHARED_DIR}/worker_sg_id"
: "Security group ID saved to: ${SHARED_DIR}/worker_sg_id"

# Matching playbook: https://raw.githubusercontent.com/openshift-storage-scale/aws-ibm-gpfs-playground/6e712d7c8261d5330ab74b1aa4a60f5279a38298/playbooks/install.yml
: 'Step 2: Adding IBM Storage Scale ports to worker security group...'

add_ingress_rule() {
  local port_spec=$1
  local description=$2
  
  : "Adding rule: ${description} (${port_spec})"
  
  if aws ec2 authorize-security-group-ingress \
    --region "${REGION}" \
    --group-id "${WORKER_SG_ID}" \
    --protocol tcp \
    --port "${port_spec}" \
    --source-group "${WORKER_SG_ID}" \
    --group-owner "$(aws sts get-caller-identity --query Account --output text --no-cli-pager)" \
    --no-cli-pager; then
    : "  Added: ${description}"
    return 0
  else
    if aws ec2 describe-security-group-rules \
      --region "${REGION}" \
      --filters "Name=group-id,Values=${WORKER_SG_ID}" \
      --query "SecurityGroupRules[?ToPort==\`${port_spec%%[-:]*}\` && IpProtocol=='tcp']" \
      --output text \
      --no-cli-pager | grep -q "${WORKER_SG_ID}"; then
      : "  Rule already exists: ${description}"
      return 0
    else
      : "  Failed to add: ${description}"
      return 1
    fi
  fi
}

add_ingress_rule "1191" "GPFS admin communication"
add_ingress_rule "12345" "GPFS daemon communication"
add_ingress_rule "60000-61000" "TSC command port range"

: 'Security group configuration completed successfully'
: "  Worker Security Group ID: ${WORKER_SG_ID}"
: "  Region: ${REGION}"
: "  Infrastructure ID: ${INFRA_ID}"
