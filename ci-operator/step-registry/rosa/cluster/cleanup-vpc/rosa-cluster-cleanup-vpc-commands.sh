#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-$LEASED_RESOURCE}"
export AWS_DEFAULT_REGION="${REGION}"

CLUSTER_NAME=""
if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME=$(head -n 1 "${SHARED_DIR}/cluster-name")
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "No cluster name found, skipping VPC cleanup"
  exit 0
fi

echo "Checking for orphaned VPC resources from cluster: ${CLUSTER_NAME}"

vpc_ids=$(aws ec2 describe-vpcs \
  --filters "Name=tag:api.openshift.com/name,Values=${CLUSTER_NAME}" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)

if [[ -z "${vpc_ids}" || "${vpc_ids}" == "None" ]]; then
  echo "No orphaned VPCs found for cluster ${CLUSTER_NAME}"
  exit 0
fi

echo "Found orphaned VPC(s): ${vpc_ids}"

for vpc_id in ${vpc_ids}; do
  echo "Cleaning up VPC: ${vpc_id}"

  echo "  Deleting VPC endpoints..."
  vpce_ids=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)
  for vpce_id in ${vpce_ids}; do
    echo "    ${vpce_id}"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${vpce_id}" 2>/dev/null || true
  done

  echo "  Deleting load balancers..."
  lb_arns=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='${vpc_id}'].LoadBalancerArn" --output text 2>/dev/null || true)
  for arn in ${lb_arns}; do
    echo "    ${arn}"
    aws elbv2 delete-load-balancer --load-balancer-arn "${arn}" 2>/dev/null || true
  done
  classic_lbs=$(aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" --output text 2>/dev/null || true)
  for lb_name in ${classic_lbs}; do
    echo "    ${lb_name}"
    aws elb delete-load-balancer --load-balancer-name "${lb_name}" 2>/dev/null || true
  done
  if [[ -n "${lb_arns}" || -n "${classic_lbs}" ]]; then
    sleep 30
  fi

  echo "  Deleting NAT gateways..."
  nat_ids=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${vpc_id}" \
    --query "NatGateways[?State!='deleted'].NatGatewayId" --output text 2>/dev/null || true)
  for nat_id in ${nat_ids}; do
    echo "    ${nat_id}"
    aws ec2 delete-nat-gateway --nat-gateway-id "${nat_id}" 2>/dev/null || true
  done
  if [[ -n "${nat_ids}" ]]; then
    echo "  Waiting for NAT gateways to delete..."
    for nat_id in ${nat_ids}; do
      aws ec2 wait nat-gateway-deleted --nat-gateway-ids "${nat_id}" 2>/dev/null || true
    done
  fi

  echo "  Releasing Elastic IPs..."
  eip_allocs=$(aws ec2 describe-addresses \
    --filters "Name=tag:api.openshift.com/name,Values=${CLUSTER_NAME}" \
    --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)
  for alloc_id in ${eip_allocs}; do
    echo "    ${alloc_id}"
    aws ec2 release-address --allocation-id "${alloc_id}" 2>/dev/null || true
  done

  echo "  Deleting network interfaces..."
  eni_ids=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
  for eni_id in ${eni_ids}; do
    att_id=$(aws ec2 describe-network-interfaces \
      --network-interface-ids "${eni_id}" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
    if [[ -n "${att_id}" && "${att_id}" != "None" ]]; then
      aws ec2 detach-network-interface --attachment-id "${att_id}" --force 2>/dev/null || true
      sleep 5
    fi
    echo "    ${eni_id}"
    aws ec2 delete-network-interface --network-interface-id "${eni_id}" 2>/dev/null || true
  done

  echo "  Deleting security groups..."
  sg_ids=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)
  for sg_id in ${sg_ids}; do
    ingress_rules=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=${sg_id}" \
      --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)
    if [[ -n "${ingress_rules}" ]]; then
      aws ec2 revoke-security-group-ingress --group-id "${sg_id}" \
        --security-group-rule-ids ${ingress_rules} 2>/dev/null || true
    fi
    egress_rules=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=${sg_id}" \
      --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)
    if [[ -n "${egress_rules}" ]]; then
      aws ec2 revoke-security-group-egress --group-id "${sg_id}" \
        --security-group-rule-ids ${egress_rules} 2>/dev/null || true
    fi
    echo "    ${sg_id}"
    aws ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null || true
  done

  echo "  Deleting subnets..."
  subnet_ids=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)
  for subnet_id in ${subnet_ids}; do
    echo "    ${subnet_id}"
    aws ec2 delete-subnet --subnet-id "${subnet_id}" 2>/dev/null || true
  done

  echo "  Deleting route tables..."
  rt_ids=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null || true)
  for rt_id in ${rt_ids}; do
    assoc_ids=$(aws ec2 describe-route-tables \
      --route-table-ids "${rt_id}" \
      --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null || true)
    for assoc_id in ${assoc_ids}; do
      aws ec2 disassociate-route-table --association-id "${assoc_id}" 2>/dev/null || true
    done
    echo "    ${rt_id}"
    aws ec2 delete-route-table --route-table-id "${rt_id}" 2>/dev/null || true
  done

  echo "  Detaching and deleting internet gateways..."
  igw_ids=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)
  for igw_id in ${igw_ids}; do
    echo "    ${igw_id}"
    aws ec2 detach-internet-gateway --internet-gateway-id "${igw_id}" --vpc-id "${vpc_id}" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "${igw_id}" 2>/dev/null || true
  done

  echo "  Deleting VPC ${vpc_id}..."
  aws ec2 delete-vpc --vpc-id "${vpc_id}" 2>/dev/null || true
done

echo "VPC cleanup complete"
exit 0
