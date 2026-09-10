#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

CLUSTER_NAME=$(oc get infrastructure cluster -o json | jq -r '.status.apiServerURL' | awk -F.  '{print$2}')
echo "Updating security group rules for data-path test on cluster $CLUSTER_NAME"

# ROSA HCP clusters use a shared VPC provisioned by the aws-provision-vpc-shared
# step, which writes vpc_info.json to SHARED_DIR. Worker node EC2 instances on
# HCP do not carry the cluster infra ID in their Name tag, so the
# describe-instances lookup below would fail. Check for vpc_info.json first;
# fall back to the EC2 instance tag lookup for Classic ROSA / OCP clusters.
if [[ -f "${SHARED_DIR}/vpc_info.json" ]]; then
  VPC=$(jq -r '.vpc_id' "${SHARED_DIR}/vpc_info.json")
  echo "VPC ID (from vpc_info.json): $VPC"
else
  VPC=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,PrivateIpAddress,PublicIpAddress, PrivateDnsName, VpcId]' --output text | column -t | grep "${CLUSTER_NAME}" | awk '{print $7}' | grep -v '^$' | sort -u)
  echo "VPC ID (from EC2 instance tags): $VPC"
fi

if [[ -z "${VPC}" ]]; then
  echo "ERROR: Could not determine VPC ID for cluster ${CLUSTER_NAME}"
  exit 1
fi

for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json | jq -r .SecurityGroups[].GroupId);
do
    echo "Adding rule to SG $sg"
    aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 10000-61000 --cidr 0.0.0.0/0
    aws ec2 authorize-security-group-ingress --group-id $sg --protocol udp --port 10000-61000 --cidr 0.0.0.0/0
done
