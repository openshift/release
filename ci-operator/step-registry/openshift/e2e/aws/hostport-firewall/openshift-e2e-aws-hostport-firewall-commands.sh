#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Open the OTE host-port range on the cluster security groups (perfscale-aws-data-path-sg pattern).
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"

CLUSTER_NAME=$(oc get infrastructure cluster -o json | jq -r '.status.apiServerURL' | awk -F. '{print $2}')
echo "Cluster: ${CLUSTER_NAME}"

VPC=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-*" \
  --query 'Reservations[0].Instances[0].VpcId' --output text)
if [[ -z "${VPC}" || "${VPC}" == "None" ]]; then
  echo "ERROR: could not find the VPC for cluster ${CLUSTER_NAME}" >&2
  exit 1
fi
echo "VPC: ${VPC}"

for sg in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC}" \
    --query 'SecurityGroups[].GroupId' --output text); do
  echo "Opening 30000-32767 on security group ${sg}"
  aws ec2 authorize-security-group-ingress --group-id "${sg}" --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id "${sg}" --protocol udp --port 30000-32767 --cidr 0.0.0.0/0
done
