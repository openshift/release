#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-$LEASED_RESOURCE}"

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "No metadata.json found, skipping GuardDuty VPC endpoint cleanup"
  exit 0
fi

infra_id=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
if [[ -z "${infra_id}" || "${infra_id}" == "null" ]]; then
  echo "No infraID in metadata.json, skipping GuardDuty VPC endpoint cleanup"
  exit 0
fi

echo "Looking up VPC for cluster infraID: ${infra_id}"

vpc_id=$(aws --region "${REGION}" ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${infra_id}-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

if [[ -z "${vpc_id}" || "${vpc_id}" == "None" ]]; then
  vpc_id=$(aws --region "${REGION}" ec2 describe-vpcs \
    --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
fi

if [[ -z "${vpc_id}" || "${vpc_id}" == "None" ]]; then
  echo "Could not determine VPC for infraID ${infra_id}, skipping GuardDuty VPC endpoint cleanup"
  exit 0
fi

echo "Found cluster VPC: ${vpc_id}"

vpce_ids=$(aws --region "${REGION}" ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${vpc_id}" \
  --query "VpcEndpoints[?contains(ServiceName, 'guardduty')].VpcEndpointId" \
  --output text 2>/dev/null || true)

if [[ -z "${vpce_ids}" ]]; then
  echo "No GuardDuty VPC endpoints found in VPC ${vpc_id}"
  exit 0
fi

for vpce_id in ${vpce_ids}; do
  service_name=$(aws --region "${REGION}" ec2 describe-vpc-endpoints \
    --vpc-endpoint-ids "${vpce_id}" \
    --query 'VpcEndpoints[0].ServiceName' --output text 2>/dev/null || true)
  echo "Deleting GuardDuty VPC endpoint ${vpce_id} (service: ${service_name})"
  aws --region "${REGION}" ec2 delete-vpc-endpoints --vpc-endpoint-ids "${vpce_id}" 2>/dev/null || true
done

echo "GuardDuty VPC endpoint cleanup complete"
exit 0
