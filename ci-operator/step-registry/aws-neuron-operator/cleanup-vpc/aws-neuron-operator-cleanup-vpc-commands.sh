#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-$LEASED_RESOURCE}"
STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-vpc"

echo "Checking for pre-existing VPC stack: ${STACK_NAME} in ${REGION}"

stack_status=""
if aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > /tmp/stack_info.json 2>/dev/null; then
  stack_status=$(jq -r '.Stacks[0].StackStatus' /tmp/stack_info.json)
  echo "Found existing stack ${STACK_NAME} in status: ${stack_status}"
else
  echo "No existing stack found, nothing to clean up"
  exit 0
fi

cleanup_vpc_resources() {
  local vpc_id="$1"
  echo "Cleaning up resources blocking VPC ${vpc_id} deletion..."

  echo "Deleting load balancers..."
  lb_arns=$(aws --region "${REGION}" elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null || true)
  for arn in ${lb_arns}; do
    echo "  Deleting load balancer: ${arn}"
    aws --region "${REGION}" elbv2 delete-load-balancer --load-balancer-arn "${arn}" || true
  done
  if [[ -n "${lb_arns}" ]]; then
    echo "  Waiting for load balancers to be deleted..."
    sleep 30
  fi

  echo "Deleting network interfaces..."
  eni_ids=$(aws --region "${REGION}" ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
  for eni_id in ${eni_ids}; do
    echo "  Detaching and deleting ENI: ${eni_id}"
    local attachment_id
    attachment_id=$(aws --region "${REGION}" ec2 describe-network-interfaces \
      --network-interface-ids "${eni_id}" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
    if [[ -n "${attachment_id}" && "${attachment_id}" != "None" ]]; then
      aws --region "${REGION}" ec2 detach-network-interface --attachment-id "${attachment_id}" --force 2>/dev/null || true
      sleep 5
    fi
    aws --region "${REGION}" ec2 delete-network-interface --network-interface-id "${eni_id}" 2>/dev/null || true
  done

  echo "Deleting security groups..."
  sg_ids=$(aws --region "${REGION}" ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)
  for sg_id in ${sg_ids}; do
    echo "  Revoking ingress/egress rules for SG: ${sg_id}"
    local ingress_rules egress_rules
    ingress_rules=$(aws --region "${REGION}" ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=${sg_id}" --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)
    if [[ -n "${ingress_rules}" ]]; then
      aws --region "${REGION}" ec2 revoke-security-group-ingress --group-id "${sg_id}" \
        --security-group-rule-ids ${ingress_rules} 2>/dev/null || true
    fi
    egress_rules=$(aws --region "${REGION}" ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=${sg_id}" --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)
    if [[ -n "${egress_rules}" ]]; then
      aws --region "${REGION}" ec2 revoke-security-group-egress --group-id "${sg_id}" \
        --security-group-rule-ids ${egress_rules} 2>/dev/null || true
    fi
    echo "  Deleting SG: ${sg_id}"
    aws --region "${REGION}" ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null || true
  done

  echo "Resource cleanup complete"
}

delete_stack() {
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" &
  wait "$!"
  echo "Delete initiated, waiting for completion..."
  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
  wait "$!"
}

case "${stack_status}" in
  DELETE_IN_PROGRESS)
    echo "Stack deletion already in progress, waiting for completion..."
    aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
    wait "$!"
    echo "Stack deletion complete"
    ;;
  DELETE_COMPLETE)
    echo "Stack already deleted, nothing to do"
    ;;
  DELETE_FAILED)
    echo "Stack in DELETE_FAILED state, cleaning up blocking resources..."
    vpc_id=$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="VpcId") | .OutputValue' /tmp/stack_info.json 2>/dev/null || true)
    if [[ -z "${vpc_id}" || "${vpc_id}" == "null" ]]; then
      vpc_id=$(aws --region "${REGION}" cloudformation describe-stack-resources \
        --stack-name "${STACK_NAME}" \
        --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' \
        --output text 2>/dev/null || true)
    fi
    if [[ -n "${vpc_id}" && "${vpc_id}" != "None" ]]; then
      cleanup_vpc_resources "${vpc_id}"
    else
      echo "WARNING: Could not determine VPC ID, attempting delete anyway"
    fi
    echo "Retrying stack deletion..."
    delete_stack
    echo "Stale stack deleted successfully"
    ;;
  *)
    echo "Deleting stale stack ${STACK_NAME} (status: ${stack_status})..."
    delete_stack
    echo "Stale stack deleted successfully"
    ;;
esac
