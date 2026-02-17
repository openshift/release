#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Configuring AWS security groups for IBM Storage Scale...'
: 'Approach: Modify existing worker security group (matching aws-ibm-gpfs-playground playbook)'

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

region="${LEASED_RESOURCE}"
export region

: "AWS credentials file: ${AWS_SHARED_CREDENTIALS_FILE}"
: "AWS region: ${region}"

clusterName="fusion-access-test"
infraId=""

if [[ -f "${SHARED_DIR}/CLUSTER_NAME" ]]; then
  clusterName="$(<"${SHARED_DIR}/CLUSTER_NAME")"
fi

if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
  infraId=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
  : "Infrastructure ID: ${infraId}"
else
  : 'ERROR: metadata.json not found'
  exit 1
fi

: "Cluster name: ${clusterName}"

# See: https://www.ibm.com/docs/en/scalecontainernative/5.2.2?topic=aws-red-hat-openshift-configuration
: 'Step 1: Finding worker security group...'

workerSgJson=$(aws ec2 describe-security-groups \
  --region "${region}" \
  --filters \
    "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node" \
    "Name=tag:Name,Values=${infraId}-*" \
  --query 'SecurityGroups[0]' \
  --output json \
 )

if [[ -z "${workerSgJson}" ]] || [[ "${workerSgJson}" == "null" ]]; then
  : 'ERROR: Could not find worker security group'
  : "Searched for tags: sigs.k8s.io/cluster-api-provider-aws/role=node, Name=${infraId}-*"
  exit 1
fi

workerSgId=$(echo "${workerSgJson}" | jq -r '.GroupId')
workerSgName=$(echo "${workerSgJson}" | jq -r '.GroupName')
workerSgDesc=$(echo "${workerSgJson}" | jq -r '.Description')

if [[ -z "${workerSgId}" ]] || [[ "${workerSgId}" == "null" ]]; then
  : 'ERROR: Failed to extract worker security group ID'
  exit 1
fi

: 'Found worker security group:'
: "  ID: ${workerSgId}"
: "  Name: ${workerSgName}"
: "  Description: ${workerSgDesc}"

echo "${workerSgId}" > "${SHARED_DIR}/worker_sg_id"
: "Security group ID saved to: ${SHARED_DIR}/worker_sg_id"

# Matching playbook: https://raw.githubusercontent.com/openshift-storage-scale/aws-ibm-gpfs-playground/6e712d7c8261d5330ab74b1aa4a60f5279a38298/playbooks/install.yml
: 'Step 2: Adding IBM Storage Scale ports to worker security group...'

AddIngressRule() {
  typeset portSpec="${1}"; (($#)) && shift
  typeset desc="${1}"; (($#)) && shift
  
  : "Adding rule: ${desc} (${portSpec})"
  
  if aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${workerSgId}" \
    --protocol tcp \
    --port "${portSpec}" \
    --source-group "${workerSgId}" \
    --group-owner "$(aws sts get-caller-identity --query Account --output text)" \
   ; then
    : "  Added: ${desc}"
    return 0
  else
    if aws ec2 describe-security-group-rules \
      --region "${region}" \
      --filters "Name=group-id,Values=${workerSgId}" \
      --query "SecurityGroupRules[?ToPort==\`${portSpec%%[-:]*}\` && IpProtocol=='tcp']" \
      --output text \
      | grep -q "${workerSgId}"; then
      : "  Rule already exists: ${desc}"
      return 0
    else
      : "  Failed to add: ${desc}"
      return 1
    fi
  fi

  true
}

AddIngressRule "1191" "GPFS admin communication"
AddIngressRule "12345" "GPFS daemon communication"
AddIngressRule "60000-61000" "TSC command port range"

: 'Security group configuration completed successfully'
: "  Worker Security Group ID: ${workerSgId}"
: "  Region: ${region}"
: "  Infrastructure ID: ${infraId}"

true
