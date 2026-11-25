#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Zero-egress VPC preparation (ROSAENG-66391). The BYO VPC provisioned by
# aws-provision-vpc-shared routes its private subnets to the internet through
# NAT gateways. A genuine zero-egress ROSA HCP cluster must instead:
#   1. reach the provision shard's ECR mirror through VPC endpoints
#      (ecr.api, ecr.dkr interface endpoints and the s3 gateway endpoint), and
#   2. have no route to the internet at all.
# This step creates the endpoints and removes the NAT routes from the private
# route tables. Public subnets keep their IGW routes so the API and ingress
# load balancers stay reachable from CI; only outbound egress is cut.
# Endpoint and security-group IDs are recorded in SHARED_DIR for
# rosa-e2e-hcp-zero-egress-vpc-cleanup, which must run before the VPC stack is
# deleted (endpoints block VPC deletion).

# Match the producer's region selection (aws-provision-vpc-shared): REGION
# wins when set, LEASED_RESOURCE (the lease region) is the fallback.
CLOUD_PROVIDER_REGION="${REGION:-${LEASED_RESOURCE}}"

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

if [[ ! -s "${SHARED_DIR}/vpc_id" || ! -s "${SHARED_DIR}/private_subnet_ids" ]]; then
  echo "ERROR: vpc_id/private_subnet_ids missing; aws-provision-vpc-shared must run first"
  exit 1
fi
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")
# private_subnet_ids holds a compact list like ['subnet-a','subnet-b']; pick
# the IDs out one per line so multi-subnet VPCs keep separate array elements.
mapfile -t PRIVATE_SUBNETS < <(grep -oE 'subnet-[0-9A-Za-z]+' "${SHARED_DIR}/private_subnet_ids")

echo "Preparing zero-egress networking for VPC ${VPC_ID} (${#PRIVATE_SUBNETS[@]} private subnets)"

# Security group for the interface endpoints: allow HTTPS from the VPC CIDR so
# nodes and control-plane components can pull from the ECR mirror.
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text)
ENDPOINT_SG_ID=$(aws ec2 create-security-group \
  --group-name "${NAMESPACE:-zero-egress}-endpoints" \
  --description "VPC endpoints for the zero-egress ECR mirror" \
  --vpc-id "${VPC_ID}" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id "${ENDPOINT_SG_ID}" --protocol tcp --port 443 --cidr "${VPC_CIDR}" >/dev/null
echo "${ENDPOINT_SG_ID}" > "${SHARED_DIR}/zero_egress_endpoint_sg_id"

# Interface endpoints for image pulls: ecr.api (authentication) and ecr.dkr
# (image layers). S3 is covered by the gateway endpoint below. Each ID is
# appended to the cleanup record as soon as AWS returns it: the step runs
# under errexit, and a later failure must not leave created endpoints
# unrecorded (cleanup deletes endpoints via this file only).
: > "${SHARED_DIR}/zero_egress_endpoint_ids"
ENDPOINT_IDS=()
for service in ecr.api ecr.dkr; do
  endpoint_id=$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Interface \
    --service-name "com.amazonaws.${CLOUD_PROVIDER_REGION}.${service}" \
    --subnet-ids "${PRIVATE_SUBNETS[@]}" \
    --security-group-ids "${ENDPOINT_SG_ID}" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)
  echo "Created ${service} interface endpoint ${endpoint_id}"
  ENDPOINT_IDS+=("${endpoint_id}")
  printf '%s\n' "${endpoint_id}" >> "${SHARED_DIR}/zero_egress_endpoint_ids"
done

# Gateway endpoint for S3 (backing store for ECR image layers). The VPC
# CloudFormation stack already creates one covering the public and private
# route tables, and AWS rejects a second route for the same service in a
# route table, so reuse the stack-owned endpoint instead of creating a
# duplicate. Only an endpoint created here is recorded for cleanup.
# Command substitution (not process substitution) so a failed enumeration
# stops the step instead of silently skipping the NAT-route removal below.
ROUTE_TABLES_RAW=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].[RouteTableId]' --output text)
mapfile -t ROUTE_TABLES <<< "${ROUTE_TABLES_RAW}"
S3_SERVICE_NAME="com.amazonaws.${CLOUD_PROVIDER_REGION}.s3"
S3_ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${S3_SERVICE_NAME}" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text)
if [[ "${S3_ENDPOINT_ID}" != "None" ]]; then
  echo "Reusing stack-owned s3 gateway endpoint ${S3_ENDPOINT_ID}"
else
  S3_ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --vpc-endpoint-type Gateway \
    --service-name "${S3_SERVICE_NAME}" \
    --route-table-ids "${ROUTE_TABLES[@]}" \
    --query 'VpcEndpoint.VpcEndpointId' --output text)
  echo "Created s3 gateway endpoint ${S3_ENDPOINT_ID}"
  ENDPOINT_IDS+=("${S3_ENDPOINT_ID}")
  printf '%s\n' "${S3_ENDPOINT_ID}" >> "${SHARED_DIR}/zero_egress_endpoint_ids"
fi

# Cut internet egress: remove every route whose target is a NAT gateway. NAT
# routes carry NatGatewayId, not GatewayId (which is null there and would make
# a starts_with(GatewayId, ...) filter error out). The routes are owned by the
# VPC CloudFormation stack, but out-of-band deletion is a no-op at stack
# teardown (CloudFormation proceeds when a resource is already gone), while
# the NAT gateways themselves stay intact for the stack's own lifecycle.
for route_table in "${ROUTE_TABLES[@]}"; do
  # Command substitution (not process substitution) so a failed lookup
  # propagates through errexit; the [DestinationCidrBlock] projection keeps
  # one CIDR per line in text output.
  NAT_ROUTES_RAW=$(aws ec2 describe-route-tables --route-table-ids "${route_table}" \
    --query 'RouteTables[0].Routes[?NatGatewayId != null].[DestinationCidrBlock]' \
    --output text)
  mapfile -t NAT_ROUTES <<< "${NAT_ROUTES_RAW}"
  for cidr in "${NAT_ROUTES[@]:-}"; do
    [[ -z "${cidr}" ]] && continue
    echo "Removing NAT route ${cidr} from ${route_table}"
    aws ec2 delete-route --route-table-id "${route_table}" --destination-cidr-block "${cidr}"
  done
done

echo "Zero-egress networking ready: ${#ENDPOINT_IDS[@]} VPC endpoints, NAT routes removed"
