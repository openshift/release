#!/bin/bash

# Discover and output all AWS resources for the cluster
#
# This script queries AWS to list cluster resources and outputs them
# to ARTIFACT_DIR for inspection and debugging.

set -eu
set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Get cluster infrastructure name
INFRA_ID="$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)"
REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"

printf "AWS Resource Discovery\n"
printf "Cluster Infrastructure ID: [%s]\n" "${INFRA_ID}"
printf "AWS Region: [%s]\n" "${REGION}"

OUTPUT_DIR="${ARTIFACT_DIR}/aws-resources"
mkdir -p "${OUTPUT_DIR}"

printf "Discovering AWS resources...\n"

# EC2 Instances
printf "\nEC2 Instances:\n"
INSTANCE_OUTPUT="${OUTPUT_DIR}/ec2-instances.json"
aws ec2 describe-instances \
  --region "${REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --output json > "${INSTANCE_OUTPUT}"

# Print summary table
printf "Instance ID | Instance Type | State | CPU Options | Name\n"
printf "%s\n" "----------- | ------------- | ----- | ----------- | ----\n"
jq -r '.Reservations[].Instances[] |
  "\(.InstanceId) | \(.InstanceType) | \(.State.Name) | \(.CpuOptions.CoreCount // "N/A")c/\(.CpuOptions.ThreadsPerCore // "N/A")t (NV:\(.CpuOptions.NestedVirtualization // "N/A")) | \((.Tags[] | select(.Key == "Name") | .Value) // "N/A")"' \
  "${INSTANCE_OUTPUT}"

printf "\nDetailed EC2 instance information saved to: [%s]\n" "${INSTANCE_OUTPUT}"

# EBS Volumes
printf "\nEBS Volumes:\n"
VOLUME_OUTPUT="${OUTPUT_DIR}/ebs-volumes.json"
aws ec2 describe-volumes \
  --region "${REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --output json > "${VOLUME_OUTPUT}"

printf "Volume ID | Size (GB) | Type | State | Attached to\n"
printf "%s\n" "--------- | --------- | ---- | ----- | -----------\n"
jq -r '.Volumes[] |
  "\(.VolumeId) | \(.Size) | \(.VolumeType) | \(.State) | \((.Attachments[0].InstanceId // "N/A"))"' \
  "${VOLUME_OUTPUT}"

printf "\nDetailed EBS volume information saved to: [%s]\n" "${VOLUME_OUTPUT}"

# Security Groups
printf "\nSecurity Groups:\n"
SG_OUTPUT="${OUTPUT_DIR}/security-groups.json"
aws ec2 describe-security-groups \
  --region "${REGION}" \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
  --output json > "${SG_OUTPUT}"

printf "Group ID | Group Name | VPC ID\n"
printf "%s\n" "-------- | ---------- | ------\n"
jq -r '.SecurityGroups[] |
  "\(.GroupId) | \(.GroupName) | \(.VpcId)"' \
  "${SG_OUTPUT}"

printf "\nDetailed security group information saved to: [%s]\n" "${SG_OUTPUT}"

# Load Balancers (Classic)
printf "\nClassic Load Balancers:\n"
CLB_OUTPUT="${OUTPUT_DIR}/classic-load-balancers.json"
aws elb describe-load-balancers \
  --region "${REGION}" \
  --output json > "${CLB_OUTPUT}" || printf "No classic load balancers found or error querying\n"

if [[ -s "${CLB_OUTPUT}" ]]; then
  jq -r --arg infra "${INFRA_ID}" '.LoadBalancerDescriptions[] |
    select(.LoadBalancerName | contains($infra)) |
    "\(.LoadBalancerName) | \(.DNSName)"' \
    "${CLB_OUTPUT}" || printf "None matching cluster ID\n"
else
  printf "None found\n"
fi

# Network Load Balancers and Application Load Balancers
printf "\nNetwork/Application Load Balancers:\n"
NLB_OUTPUT="${OUTPUT_DIR}/network-application-load-balancers.json"
aws elbv2 describe-load-balancers \
  --region "${REGION}" \
  --output json > "${NLB_OUTPUT}" || printf "No NLB/ALB found or error querying\n"

if [[ -s "${NLB_OUTPUT}" ]]; then
  jq -r --arg infra "${INFRA_ID}" '.LoadBalancers[] |
    select(.LoadBalancerName | contains($infra)) |
    "\(.LoadBalancerName) | \(.Type) | \(.DNSName)"' \
    "${NLB_OUTPUT}" || printf "None matching cluster ID\n"
else
  printf "None found\n"
fi

# VPC and Subnets
printf "\nVPC and Subnets:\n"
VPC_OUTPUT="${OUTPUT_DIR}/vpc.json"
SUBNET_OUTPUT="${OUTPUT_DIR}/subnets.json"

# Get VPC ID from an instance
VPC_ID=$(jq -r '.Reservations[0].Instances[0].VpcId // empty' "${INSTANCE_OUTPUT}")

if [[ -n "${VPC_ID}" ]]; then
  aws ec2 describe-vpcs \
    --region "${REGION}" \
    --vpc-ids "${VPC_ID}" \
    --output json > "${VPC_OUTPUT}"

  printf "VPC ID: [%s]\n" "${VPC_ID}"
  printf "CIDR Block: [%s]\n" "$(jq -r '.Vpcs[0].CidrBlock' "${VPC_OUTPUT}")"

  aws ec2 describe-subnets \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --output json > "${SUBNET_OUTPUT}"

  printf "\nSubnet ID | CIDR | Availability Zone | Name\n"
  printf "%s\n" "--------- | ---- | ----------------- | ----"
  jq -r '.Subnets[] |
    "\(.SubnetId) | \(.CidrBlock) | \(.AvailabilityZone) | \((.Tags[] | select(.Key == "Name") | .Value) // "N/A")"' \
    "${SUBNET_OUTPUT}"
else
  printf "Could not determine VPC ID\n"
fi

printf "\nResource discovery complete\n"
printf "All outputs saved to: [%s]" "${OUTPUT_DIR}"
