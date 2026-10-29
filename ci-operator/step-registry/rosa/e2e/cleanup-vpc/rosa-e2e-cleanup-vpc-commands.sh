#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-$LEASED_RESOURCE}"

# Read the VPC stack name from shared dir
STACK_NAME=""
stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list"
if [[ -f "${stack_list}" ]]; then
  STACK_NAME=$(head -n 1 "${stack_list}")
fi

if [[ -z "${STACK_NAME}" ]]; then
  echo "No VPC stack to clean up"
  exit 0
fi

echo "Cleaning up resources for VPC stack: ${STACK_NAME}"

# Get VPC ID from the CloudFormation stack
vpc_id=""
if aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > /tmp/stack_info.json 2>/dev/null; then
  vpc_id=$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="VpcId") | .OutputValue' /tmp/stack_info.json 2>/dev/null || true)
fi

if [[ -z "${vpc_id}" || "${vpc_id}" == "null" ]]; then
  vpc_id=$(aws --region "${REGION}" cloudformation describe-stack-resources \
    --stack-name "${STACK_NAME}" \
    --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' \
    --output text 2>/dev/null || true)
fi

if [[ -z "${vpc_id}" || "${vpc_id}" == "None" ]]; then
  echo "Could not determine VPC ID, skipping cleanup"
  exit 0
fi

echo "Found VPC: ${vpc_id}"

# Delete VPC endpoints (AVO leftovers)
echo "Deleting VPC endpoints..."
vpce_ids=$(aws --region "${REGION}" ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${vpc_id}" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)
for vpce_id in ${vpce_ids}; do
  echo "  Deleting VPC endpoint: ${vpce_id}"
  aws --region "${REGION}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "${vpce_id}" 2>/dev/null || true
done

# Delete load balancers
echo "Deleting load balancers..."
lb_arns=$(aws --region "${REGION}" elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null || true)
for arn in ${lb_arns}; do
  echo "  Deleting load balancer: ${arn}"
  aws --region "${REGION}" elbv2 delete-load-balancer --load-balancer-arn "${arn}" 2>/dev/null || true
done

# Also check classic ELBs
classic_lbs=$(aws --region "${REGION}" elb describe-load-balancers \
  --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" --output text 2>/dev/null || true)
for lb_name in ${classic_lbs}; do
  echo "  Deleting classic load balancer: ${lb_name}"
  aws --region "${REGION}" elb delete-load-balancer --load-balancer-name "${lb_name}" 2>/dev/null || true
done

if [[ -n "${lb_arns}" || -n "${classic_lbs}" ]]; then
  echo "  Waiting for load balancers to drain..."
  sleep 30
fi

# Detach and delete network interfaces
echo "Deleting network interfaces..."
eni_ids=$(aws --region "${REGION}" ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=${vpc_id}" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
for eni_id in ${eni_ids}; do
  attachment_id=$(aws --region "${REGION}" ec2 describe-network-interfaces \
    --network-interface-ids "${eni_id}" \
    --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
  if [[ -n "${attachment_id}" && "${attachment_id}" != "None" ]]; then
    echo "  Detaching ENI: ${eni_id} (attachment: ${attachment_id})"
    aws --region "${REGION}" ec2 detach-network-interface --attachment-id "${attachment_id}" --force 2>/dev/null || true
    sleep 5
  fi
  echo "  Deleting ENI: ${eni_id}"
  aws --region "${REGION}" ec2 delete-network-interface --network-interface-id "${eni_id}" 2>/dev/null || true
done

# Delete non-default security groups
echo "Deleting security groups..."
sg_ids=$(aws --region "${REGION}" ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${vpc_id}" \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)
for sg_id in ${sg_ids}; do
  # Revoke all rules first to break circular references
  ingress_rules=$(aws --region "${REGION}" ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${sg_id}" \
    --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)
  if [[ -n "${ingress_rules}" ]]; then
    aws --region "${REGION}" ec2 revoke-security-group-ingress --group-id "${sg_id}" \
      --security-group-rule-ids ${ingress_rules} 2>/dev/null || true
  fi
  egress_rules=$(aws --region "${REGION}" ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=${sg_id}" \
    --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)
  if [[ -n "${egress_rules}" ]]; then
    aws --region "${REGION}" ec2 revoke-security-group-egress --group-id "${sg_id}" \
      --security-group-rule-ids ${egress_rules} 2>/dev/null || true
  fi
  echo "  Deleting SG: ${sg_id}"
  aws --region "${REGION}" ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null || true
done

echo "VPC resource cleanup complete"
exit 0
