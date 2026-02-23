#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

typeset region="${LEASED_RESOURCE}"
typeset infraId=''
infraId=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")

# See: https://www.ibm.com/docs/en/scalecontainernative/5.2.2?topic=aws-red-hat-openshift-configuration
typeset workerSgId=''
workerSgId="$(
  aws ec2 describe-security-groups \
    --region "${region}" \
    --filters \
      "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node" \
      "Name=tag:Name,Values=${infraId}-*" \
    --query 'SecurityGroups[0]' \
    --output json |
  jq -cr '.GroupId'
)"
[[ "${workerSgId}" == "null" ]] && false

echo "${workerSgId}" > "${SHARED_DIR}/worker_sg_id"

# Matching playbook: https://raw.githubusercontent.com/openshift-storage-scale/aws-ibm-gpfs-playground/6e712d7c8261d5330ab74b1aa4a60f5279a38298/playbooks/install.yml
AddIngressRule() {
  typeset portSpec="${1}"; (($#)) && shift
  typeset desc="${1}"; (($#)) && shift
  typeset stderr

  if stderr=$({ aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${workerSgId}" \
    --protocol tcp \
    --port "${portSpec}" \
    --source-group "${workerSgId}" \
    --group-owner "$(aws sts get-caller-identity --query Account --output text)" \
    2>&1 1>&3; } 3>&2); then
    : "  Added: ${desc}"
  elif [[ "${stderr}" == *'InvalidPermission.Duplicate'* ]]; then
    : "  Rule already exists: ${desc}"
  else
    printf '%s\n' "${stderr}" >&2
    return 1
  fi

  true
}

AddIngressRule "1191" "GPFS admin communication"
AddIngressRule "12345" "GPFS daemon communication"
AddIngressRule "60000-61000" "TSC command port range"

true
