#!/usr/bin/env bash
# Describe AWS Cluster resources which were created by a previous install.
#
# This script queries AWS using the Resource Groups Tagging API to discover all
# cluster resources, then fetches details for each resource type.

set -o nounset
set -o errexit
set -o pipefail

# Set up AWS credentials from the cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
  AWS_REGION=$(yq-go r "${SHARED_DIR}/install-config.yaml" 'platform.aws.region')
else
  echo "WARNING: install-config.yaml not found, falling back to LEASED_RESOURCE"
  AWS_REGION="${LEASED_RESOURCE}"
fi

if [[ -z "${AWS_REGION}" || "${AWS_REGION}" == "null" ]]; then
  echo "ERROR: Could not determine AWS region"
  exit 1
fi

export AWS_DEFAULT_REGION="${AWS_REGION}"
echo "AWS Region: ${AWS_REGION}"

# Get the cluster infrastructure name to filter instances
INFRA_ID=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")

if [[ -z "${INFRA_ID}" || "${INFRA_ID}" == "null" ]]; then
  echo "ERROR: Could not determine cluster infrastructure ID from metadata.json"
  exit 1
fi

echo "Cluster Infrastructure ID: ${INFRA_ID}"
echo "Discovering all AWS resources for cluster: ${INFRA_ID}"

JSON_FILE="${ARTIFACT_DIR}/aws-cluster-describe.json"
SUMMARY_FILE="${ARTIFACT_DIR}/aws-cluster-describe.log"

# Discover all resources using Resource Groups Tagging API
echo "Querying regional tagged resources via Resource Groups Tagging API..."
# Temporarily disable errexit for command substitution to allow error handling
set +e
TAGGED_RESOURCES_OUTPUT=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>&1)
TAGGED_RESOURCES_EXIT_CODE=$?
set -e

if [[ ${TAGGED_RESOURCES_EXIT_CODE} -ne 0 ]]; then
  echo "ERROR: Failed to query resource tagging API in region ${AWS_REGION}"
  echo "${TAGGED_RESOURCES_OUTPUT}"
  echo "This may indicate missing tag:GetResources permission or API unavailability"
  TAGGED_RESOURCES=""
else
  TAGGED_RESOURCES=$(echo "${TAGGED_RESOURCES_OUTPUT}" | jq -r '.ResourceTagMappingList[] | .ResourceARN' 2>/dev/null) || TAGGED_RESOURCES=""
  if [[ -z "${TAGGED_RESOURCES}" ]]; then
    echo "WARNING: No regional resources found with tag kubernetes.io/cluster/${INFRA_ID}=owned"
  fi
fi

# Query global IAM and Route53 resources from the partition's global region
# Determine global region based on partition (us-east-1 for commercial, us-gov-west-1 for GovCloud)
if [[ "${AWS_REGION}" =~ ^us-gov- ]]; then
  GLOBAL_REGION="us-gov-west-1"
elif [[ "${AWS_REGION}" =~ ^cn- ]]; then
  GLOBAL_REGION="cn-north-1"
else
  GLOBAL_REGION="us-east-1"
fi
echo "Querying global IAM and Route53 resources from ${GLOBAL_REGION}..."
# Temporarily disable errexit for command substitution to allow error handling
set +e
GLOBAL_TAGGED_RESOURCES_OUTPUT=$(aws resourcegroupstaggingapi get-resources \
    --region "${GLOBAL_REGION}" \
    --resource-type-filters iam:instance-profile route53:hostedzone \
    --tag-filters "Key=kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>&1)
GLOBAL_EXIT_CODE=$?
set -e

if [[ ${GLOBAL_EXIT_CODE} -ne 0 ]]; then
  echo "WARNING: Failed to query global resources from ${GLOBAL_REGION} (IAM/Route53 may be missing)"
  echo "${GLOBAL_TAGGED_RESOURCES_OUTPUT}"
  GLOBAL_TAGGED_RESOURCES=""
else
  GLOBAL_TAGGED_RESOURCES=$(echo "${GLOBAL_TAGGED_RESOURCES_OUTPUT}" | jq -r '.ResourceTagMappingList[] | .ResourceARN' 2>/dev/null) || GLOBAL_TAGGED_RESOURCES=""
fi

# Extract resource IDs by type from ARNs
EC2_INSTANCE_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':instance/' | sed 's|.*/||' | tr '\n' ' ') || EC2_INSTANCE_IDS=""
VOLUME_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':volume/' | sed 's|.*/||' | tr '\n' ' ') || VOLUME_IDS=""
VPC_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':vpc/' | sed 's|.*/||' | tr '\n' ' ') || VPC_IDS=""
SUBNET_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':subnet/' | sed 's|.*/||' | tr '\n' ' ') || SUBNET_IDS=""
SG_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':security-group/' | sed 's|.*/||' | tr '\n' ' ') || SG_IDS=""
RTB_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':route-table/' | sed 's|.*/||' | tr '\n' ' ') || RTB_IDS=""
IGW_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':internet-gateway/' | sed 's|.*/||' | tr '\n' ' ') || IGW_IDS=""
NAT_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':natgateway/' | sed 's|.*/||' | tr '\n' ' ') || NAT_IDS=""
EIP_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':elastic-ip/' | sed 's|.*/||' | tr '\n' ' ') || EIP_IDS=""
ENI_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':network-interface/' | sed 's|.*/||' | tr '\n' ' ') || ENI_IDS=""
VPCE_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':vpc-endpoint/' | sed 's|.*/||' | tr '\n' ' ') || VPCE_IDS=""
NACL_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':network-acl/' | sed 's|.*/||' | tr '\n' ' ') || NACL_IDS=""
DHCP_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':dhcp-options/' | sed 's|.*/||' | tr '\n' ' ') || DHCP_IDS=""
PEERING_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':vpc-peering-connection/' | sed 's|.*/||' | tr '\n' ' ') || PEERING_IDS=""
S3_BUCKETS=$(echo "${TAGGED_RESOURCES}" | grep -E '^arn:aws[a-z-]*:s3:::' | sed 's|^arn:[^:]*:s3:::||' | tr '\n' ' ') || S3_BUCKETS=""
KMS_KEY_IDS=$(echo "${TAGGED_RESOURCES}" | grep ':key/' | sed 's|.*/||' | tr '\n' ' ') || KMS_KEY_IDS=""

# IAM instance profiles and Route53 hosted zones are global resources in us-east-1
IAM_PROFILE_NAMES=$(echo "${GLOBAL_TAGGED_RESOURCES}" | grep ':instance-profile/' | sed 's|.*/||' | tr '\n' ' ') || IAM_PROFILE_NAMES=""
HOSTED_ZONE_IDS=$(echo "${GLOBAL_TAGGED_RESOURCES}" | grep 'route53:::hostedzone/' | sed 's|.*/||' | tr '\n' ' ') || HOSTED_ZONE_IDS=""

# IAM roles are not returned by GetResources API, and list-roles doesn't return tags
# Use list-roles to get all role names, then filter by tags using list-role-tags
# To avoid timeout with large role counts, pre-filter by name pattern containing INFRA_ID
echo "Discovering IAM roles via IAM API..."
IAM_ROLE_NAMES=""
ALL_ROLES=$(aws iam list-roles --output json 2>/dev/null | \
    jq -r --arg infra "${INFRA_ID}" '.Roles[] | select(.RoleName | contains($infra)) | .RoleName' 2>/dev/null) || ALL_ROLES=""
if [[ -n "${ALL_ROLES}" ]]; then
  ROLE_COUNT=$(echo "${ALL_ROLES}" | wc -l)
  echo "Found ${ROLE_COUNT} roles matching name pattern '${INFRA_ID}', checking tags..."
  for role_name in ${ALL_ROLES}; do
    ROLE_TAGS_OUTPUT=$(aws iam list-role-tags --role-name "${role_name}" --output json 2>&1)
    ROLE_TAGS_EXIT=$?
    if [[ ${ROLE_TAGS_EXIT} -ne 0 ]]; then
      echo "WARNING: Failed to read tags for role ${role_name}: ${ROLE_TAGS_OUTPUT}"
      continue
    fi
    ROLE_TAGS=$(echo "${ROLE_TAGS_OUTPUT}" | jq -r --arg cluster "kubernetes.io/cluster/${INFRA_ID}" --arg value "owned" \
        '.Tags[] | select(.Key == $cluster and .Value == $value) | .Key' 2>/dev/null) || ROLE_TAGS=""
    if [[ -n "${ROLE_TAGS}" ]]; then
      IAM_ROLE_NAMES="${IAM_ROLE_NAMES}${role_name} "
    fi
  done
fi

# Query EC2 instances
if [[ -n "${EC2_INSTANCE_IDS}" ]]; then
  echo "Fetching EC2 instance details..."
  INSTANCES_JSON=$(aws ec2 describe-instances \
      --instance-ids ${EC2_INSTANCE_IDS} \
      --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
      --output json | jq '[
        .Reservations[].Instances[] |
        if .PublicIpAddress then .PublicIpAddress = "REDACTED" else . end |
        if .PublicDnsName then .PublicDnsName = "REDACTED" else . end |
        if .Ipv6Address then .Ipv6Address = "REDACTED" else . end |
        if .IamInstanceProfile then
          .IamInstanceProfile.Arn |= gsub(":[0-9]{12}:"; ":REDACTED:")
        else . end |
        if .NetworkInterfaces then
          .NetworkInterfaces |= map(
            .OwnerId = "REDACTED" |
            if .Association then
              .Association |= (
                if .PublicIp then .PublicIp = "REDACTED" else . end |
                if .PublicDnsName then .PublicDnsName = "REDACTED" else . end |
                if .IpOwnerId then .IpOwnerId = "REDACTED" else . end
              )
            else . end |
            if .Ipv6Addresses then
              .Ipv6Addresses |= map(if .Ipv6Address then .Ipv6Address = "REDACTED" else . end)
            else . end |
            if .PrivateIpAddresses then
              .PrivateIpAddresses |= map(
                if .Association then
                  .Association |= (
                    if .PublicIp then .PublicIp = "REDACTED" else . end |
                    if .PublicDnsName then .PublicDnsName = "REDACTED" else . end |
                    if .IpOwnerId then .IpOwnerId = "REDACTED" else . end
                  )
                else . end
              )
            else . end
          )
        else . end
      ]') || INSTANCES_JSON="[]"
else
  INSTANCES_JSON="[]"
fi

# Query EBS volumes
# Use tag filter instead of volume IDs to handle deleted volumes gracefully
echo "Fetching EBS volume details..."
VOLUMES_JSON=$(aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json | jq '.Volumes') || VOLUMES_JSON="[]"

# Query VPCs
if [[ -n "${VPC_IDS}" ]]; then
  echo "Fetching VPC details..."
  VPCS_JSON=$(aws ec2 describe-vpcs \
      --vpc-ids ${VPC_IDS} \
      --output json | jq '[
        .Vpcs[] |
        .OwnerId = "REDACTED"
      ]') || VPCS_JSON="[]"
else
  VPCS_JSON="[]"
fi

# Query Subnets
if [[ -n "${SUBNET_IDS}" ]]; then
  echo "Fetching subnet details..."
  SUBNETS_JSON=$(aws ec2 describe-subnets \
      --subnet-ids ${SUBNET_IDS} \
      --output json | jq '[
        .Subnets[] |
        .OwnerId = "REDACTED"
      ]') || SUBNETS_JSON="[]"
else
  SUBNETS_JSON="[]"
fi

# Query Security Groups
if [[ -n "${SG_IDS}" ]]; then
  echo "Fetching security group details..."
  SECURITY_GROUPS_JSON=$(aws ec2 describe-security-groups \
      --group-ids ${SG_IDS} \
      --output json | jq '[
        .SecurityGroups[] |
        .OwnerId = "REDACTED" |
        if .IpPermissions then
          .IpPermissions |= map(
            if .UserIdGroupPairs then
              .UserIdGroupPairs |= map(if .UserId then .UserId = "REDACTED" else . end)
            else . end
          )
        else . end |
        if .IpPermissionsEgress then
          .IpPermissionsEgress |= map(
            if .UserIdGroupPairs then
              .UserIdGroupPairs |= map(if .UserId then .UserId = "REDACTED" else . end)
            else . end
          )
        else . end
      ]') || SECURITY_GROUPS_JSON="[]"
else
  SECURITY_GROUPS_JSON="[]"
fi

# Query Route Tables
if [[ -n "${RTB_IDS}" ]]; then
  echo "Fetching route table details..."
  ROUTE_TABLES_JSON=$(aws ec2 describe-route-tables \
      --route-table-ids ${RTB_IDS} \
      --output json | jq '[
        .RouteTables[] |
        .OwnerId = "REDACTED" |
        if .Routes then
          .Routes |= map(if .InstanceOwnerId then .InstanceOwnerId = "REDACTED" else . end)
        else . end
      ]') || ROUTE_TABLES_JSON="[]"
else
  ROUTE_TABLES_JSON="[]"
fi

# Query Internet Gateways
if [[ -n "${IGW_IDS}" ]]; then
  echo "Fetching internet gateway details..."
  INTERNET_GATEWAYS_JSON=$(aws ec2 describe-internet-gateways \
      --internet-gateway-ids ${IGW_IDS} \
      --output json | jq '.InternetGateways') || INTERNET_GATEWAYS_JSON="[]"
else
  INTERNET_GATEWAYS_JSON="[]"
fi

# Query NAT Gateways
if [[ -n "${NAT_IDS}" ]]; then
  echo "Fetching NAT gateway details..."
  NAT_GATEWAYS_JSON=$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids ${NAT_IDS} \
      --output json | jq '[
        .NatGateways[] |
        .NatGatewayAddresses |= map(
          if .PublicIp then .PublicIp = "REDACTED" else . end
        )
      ]') || NAT_GATEWAYS_JSON="[]"
else
  NAT_GATEWAYS_JSON="[]"
fi

# Query Elastic IPs
if [[ -n "${EIP_IDS}" ]]; then
  echo "Fetching Elastic IP details..."
  ELASTIC_IPS_JSON=$(aws ec2 describe-addresses \
      --allocation-ids ${EIP_IDS} \
      --output json | jq '[
        .Addresses[] |
        if .PublicIp then .PublicIp = "REDACTED" else . end |
        if .NetworkInterfaceOwnerId then .NetworkInterfaceOwnerId = "REDACTED" else . end
      ]') || ELASTIC_IPS_JSON="[]"
else
  ELASTIC_IPS_JSON="[]"
fi

# Query Network Interfaces
if [[ -n "${ENI_IDS}" ]]; then
  echo "Fetching network interface details..."
  NETWORK_INTERFACES_JSON=$(aws ec2 describe-network-interfaces \
      --network-interface-ids ${ENI_IDS} \
      --output json | jq '[
        .NetworkInterfaces[] |
        .OwnerId = "REDACTED" |
        if .Attachment then
          .Attachment |= (if .InstanceOwnerId then .InstanceOwnerId = "REDACTED" else . end)
        else . end |
        if .Association then
          .Association |= (
            if .PublicIp then .PublicIp = "REDACTED" else . end |
            if .PublicDnsName then .PublicDnsName = "REDACTED" else . end |
            if .IpOwnerId then .IpOwnerId = "REDACTED" else . end
          )
        else . end |
        if .Ipv6Addresses then
          .Ipv6Addresses |= map(if .Ipv6Address then .Ipv6Address = "REDACTED" else . end)
        else . end |
        if .PrivateIpAddresses then
          .PrivateIpAddresses |= map(
            if .Association then
              .Association |= (
                if .PublicIp then .PublicIp = "REDACTED" else . end |
                if .PublicDnsName then .PublicDnsName = "REDACTED" else . end |
                if .IpOwnerId then .IpOwnerId = "REDACTED" else . end
              )
            else . end
          )
        else . end
      ]') || NETWORK_INTERFACES_JSON="[]"
else
  NETWORK_INTERFACES_JSON="[]"
fi

# Query VPC Endpoints
if [[ -n "${VPCE_IDS}" ]]; then
  echo "Fetching VPC endpoint details..."
  VPC_ENDPOINTS_JSON=$(aws ec2 describe-vpc-endpoints \
      --vpc-endpoint-ids ${VPCE_IDS} \
      --output json | jq '[
        .VpcEndpoints[] |
        .OwnerId = "REDACTED" |
        if .PolicyDocument then .PolicyDocument = "REDACTED" else . end
      ]') || VPC_ENDPOINTS_JSON="[]"
else
  VPC_ENDPOINTS_JSON="[]"
fi

# Query Network ACLs
if [[ -n "${NACL_IDS}" ]]; then
  echo "Fetching network ACL details..."
  NETWORK_ACLS_JSON=$(aws ec2 describe-network-acls \
      --network-acl-ids ${NACL_IDS} \
      --output json | jq '[
        .NetworkAcls[] |
        .OwnerId = "REDACTED"
      ]') || NETWORK_ACLS_JSON="[]"
else
  NETWORK_ACLS_JSON="[]"
fi

# Query DHCP Option Sets
if [[ -n "${DHCP_IDS}" ]]; then
  echo "Fetching DHCP option set details..."
  DHCP_OPTIONS_JSON=$(aws ec2 describe-dhcp-options \
      --dhcp-options-ids ${DHCP_IDS} \
      --output json | jq '[
        .DhcpOptions[] |
        .OwnerId = "REDACTED"
      ]') || DHCP_OPTIONS_JSON="[]"
else
  DHCP_OPTIONS_JSON="[]"
fi

# Query VPC Peering Connections
if [[ -n "${PEERING_IDS}" ]]; then
  echo "Fetching VPC peering connection details..."
  VPC_PEERINGS_JSON=$(aws ec2 describe-vpc-peering-connections \
      --vpc-peering-connection-ids ${PEERING_IDS} \
      --output json | jq '[
        .VpcPeeringConnections[] |
        .AccepterVpcInfo.OwnerId = "REDACTED" |
        .RequesterVpcInfo.OwnerId = "REDACTED"
      ]') || VPC_PEERINGS_JSON="[]"
else
  VPC_PEERINGS_JSON="[]"
fi

# Query Load Balancers (Classic) - these may not be directly taggable, so use name matching
echo "Fetching classic load balancers..."
LOAD_BALANCERS_JSON=$(aws elb describe-load-balancers --output json 2>/dev/null | \
    jq --arg infra "${INFRA_ID}" '[
      .LoadBalancerDescriptions[] |
      select(.LoadBalancerName | contains($infra))
    ]') || LOAD_BALANCERS_JSON="[]"

# Query Load Balancers V2 (ALB/NLB) - check tags via ARNs
echo "Fetching application/network load balancers..."
LB_V2_ARNS=$(echo "${TAGGED_RESOURCES}" | grep 'elasticloadbalancing:[^:]*:[^:]*:loadbalancer/' || true)
if [[ -n "${LB_V2_ARNS}" ]]; then
  # Use temp file to avoid 128KB kernel arg limit with large ARN lists
  LB_ARNS_FILE=$(mktemp)
  echo "${LB_V2_ARNS}" | jq -R -s 'split("\n") | map(select(length > 0))' > "${LB_ARNS_FILE}"
  LOAD_BALANCERS_V2_JSON=$(aws elbv2 describe-load-balancers --output json 2>/dev/null | \
      jq --slurpfile arns "${LB_ARNS_FILE}" '[
        .LoadBalancers[] |
        select(.LoadBalancerArn as $arn | $arns[0] | index($arn)) |
        .LoadBalancerArn |= gsub(":[0-9]{12}:"; ":REDACTED:") |
        if .AvailabilityZones then
          .AvailabilityZones |= map(
            if .LoadBalancerAddresses then
              .LoadBalancerAddresses |= map(
                if .IpAddress then .IpAddress = "REDACTED" else . end
              )
            else . end
          )
        else . end
      ]') || LOAD_BALANCERS_V2_JSON="[]"
  rm -f "${LB_ARNS_FILE}"
else
  LOAD_BALANCERS_V2_JSON="[]"
fi

# Query Target Groups
echo "Fetching target groups..."
TG_ARNS=$(echo "${TAGGED_RESOURCES}" | grep 'elasticloadbalancing:[^:]*:[^:]*:targetgroup/' || true)
if [[ -n "${TG_ARNS}" ]]; then
  # Use temp file to avoid 128KB kernel arg limit with large ARN lists
  TG_ARNS_FILE=$(mktemp)
  echo "${TG_ARNS}" | jq -R -s 'split("\n") | map(select(length > 0))' > "${TG_ARNS_FILE}"
  TARGET_GROUPS_JSON=$(aws elbv2 describe-target-groups --output json 2>/dev/null | \
      jq --slurpfile arns "${TG_ARNS_FILE}" '[
        .TargetGroups[] |
        select(.TargetGroupArn as $arn | $arns[0] | index($arn)) |
        .TargetGroupArn |= gsub(":[0-9]{12}:"; ":REDACTED:") |
        if .LoadBalancerArns then
          .LoadBalancerArns |= map(gsub(":[0-9]{12}:"; ":REDACTED:"))
        else . end
      ]') || TARGET_GROUPS_JSON="[]"
  rm -f "${TG_ARNS_FILE}"
else
  TARGET_GROUPS_JSON="[]"
fi

# Query S3 Buckets
if [[ -n "${S3_BUCKETS}" ]]; then
  echo "Fetching S3 bucket details..."
  S3_BUCKETS_JSON="[]"
  for bucket in ${S3_BUCKETS}; do
    BUCKET_INFO=$(aws s3api get-bucket-location --bucket "${bucket}" 2>/dev/null | \
        jq --arg name "${bucket}" '{BucketName: $name, Location: .LocationConstraint}' 2>/dev/null) || BUCKET_INFO="{}"
    if [[ "${BUCKET_INFO}" != "{}" ]]; then
      S3_BUCKETS_JSON=$(echo "${S3_BUCKETS_JSON}" | jq --argjson bucket "${BUCKET_INFO}" '. + [$bucket]')
    fi
  done
else
  S3_BUCKETS_JSON="[]"
fi

# Query KMS Keys
if [[ -n "${KMS_KEY_IDS}" ]]; then
  echo "Fetching KMS key details..."
  KMS_KEYS_JSON="[]"
  for key_id in ${KMS_KEY_IDS}; do
    KEY_INFO=$(aws kms describe-key --key-id "${key_id}" 2>/dev/null | jq '.KeyMetadata |
      .AWSAccountId = "REDACTED" |
      .Arn |= gsub(":[0-9]{12}:"; ":REDACTED:") |
      if .MultiRegionConfiguration then
        .MultiRegionConfiguration |= (
          if .PrimaryKey then
            .PrimaryKey.Arn |= gsub(":[0-9]{12}:"; ":REDACTED:")
          else . end |
          if .ReplicaKeys then
            .ReplicaKeys |= map(.Arn |= gsub(":[0-9]{12}:"; ":REDACTED:"))
          else . end
        )
      else . end
    ') || KEY_INFO="{}"
    if [[ "${KEY_INFO}" != "{}" ]]; then
      KMS_KEYS_JSON=$(echo "${KMS_KEYS_JSON}" | jq --argjson key "${KEY_INFO}" '. + [$key]')
    fi
  done
else
  KMS_KEYS_JSON="[]"
fi

# Query IAM Roles
if [[ -n "${IAM_ROLE_NAMES}" ]]; then
  echo "Fetching IAM role details..."
  IAM_ROLES_JSON="[]"
  for role_name in ${IAM_ROLE_NAMES}; do
    ROLE_INFO=$(aws iam get-role --role-name "${role_name}" 2>/dev/null | jq '.Role |
      .Arn |= gsub(":[0-9]{12}:"; ":REDACTED:") |
      .AssumeRolePolicyDocument = "REDACTED" |
      if .PermissionsBoundary then
        .PermissionsBoundary.PermissionsBoundaryArn |= gsub(":[0-9]{12}:"; ":REDACTED:")
      else . end
    ') || ROLE_INFO="{}"
    if [[ "${ROLE_INFO}" != "{}" ]]; then
      IAM_ROLES_JSON=$(echo "${IAM_ROLES_JSON}" | jq --argjson role "${ROLE_INFO}" '. + [$role]')
    fi
  done
else
  IAM_ROLES_JSON="[]"
fi

# Query IAM Instance Profiles
if [[ -n "${IAM_PROFILE_NAMES}" ]]; then
  echo "Fetching IAM instance profile details..."
  IAM_PROFILES_JSON="[]"
  for profile_name in ${IAM_PROFILE_NAMES}; do
    PROFILE_INFO=$(aws iam get-instance-profile --instance-profile-name "${profile_name}" 2>/dev/null | jq '.InstanceProfile |
      .Arn |= gsub(":[0-9]{12}:"; ":REDACTED:") |
      .Roles |= map(
        .Arn |= gsub(":[0-9]{12}:"; ":REDACTED:") |
        .AssumeRolePolicyDocument = "REDACTED" |
        if .PermissionsBoundary then
          .PermissionsBoundary.PermissionsBoundaryArn |= gsub(":[0-9]{12}:"; ":REDACTED:")
        else . end
      )
    ') || PROFILE_INFO="{}"
    if [[ "${PROFILE_INFO}" != "{}" ]]; then
      IAM_PROFILES_JSON=$(echo "${IAM_PROFILES_JSON}" | jq --argjson profile "${PROFILE_INFO}" '. + [$profile]')
    fi
  done
else
  IAM_PROFILES_JSON="[]"
fi

# Query Route53 Hosted Zones
if [[ -n "${HOSTED_ZONE_IDS}" ]]; then
  echo "Fetching Route53 hosted zone details..."
  HOSTED_ZONES_JSON="[]"
  for zone_id in ${HOSTED_ZONE_IDS}; do
    ZONE_INFO=$(aws route53 get-hosted-zone --id "${zone_id}" 2>/dev/null | jq '.HostedZone') || ZONE_INFO="{}"
    if [[ "${ZONE_INFO}" != "{}" ]]; then
      HOSTED_ZONES_JSON=$(echo "${HOSTED_ZONES_JSON}" | jq --argjson zone "${ZONE_INFO}" '. + [$zone]')
    fi
  done
else
  HOSTED_ZONES_JSON="[]"
fi

# Combine into single JSON using temp files to avoid 128KB kernel arg limit
# Create temp directory for JSON fragments
TEMP_JSON_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_JSON_DIR}"' EXIT

# Write each collection to a temp file
echo "${INSTANCES_JSON}" > "${TEMP_JSON_DIR}/instances.json"
echo "${VOLUMES_JSON}" > "${TEMP_JSON_DIR}/volumes.json"
echo "${VPCS_JSON}" > "${TEMP_JSON_DIR}/vpcs.json"
echo "${SUBNETS_JSON}" > "${TEMP_JSON_DIR}/subnets.json"
echo "${SECURITY_GROUPS_JSON}" > "${TEMP_JSON_DIR}/securityGroups.json"
echo "${LOAD_BALANCERS_JSON}" > "${TEMP_JSON_DIR}/loadBalancers.json"
echo "${LOAD_BALANCERS_V2_JSON}" > "${TEMP_JSON_DIR}/loadBalancersV2.json"
echo "${TARGET_GROUPS_JSON}" > "${TEMP_JSON_DIR}/targetGroups.json"
echo "${ROUTE_TABLES_JSON}" > "${TEMP_JSON_DIR}/routeTables.json"
echo "${INTERNET_GATEWAYS_JSON}" > "${TEMP_JSON_DIR}/internetGateways.json"
echo "${NAT_GATEWAYS_JSON}" > "${TEMP_JSON_DIR}/natGateways.json"
echo "${ELASTIC_IPS_JSON}" > "${TEMP_JSON_DIR}/elasticIps.json"
echo "${NETWORK_INTERFACES_JSON}" > "${TEMP_JSON_DIR}/networkInterfaces.json"
echo "${VPC_ENDPOINTS_JSON}" > "${TEMP_JSON_DIR}/vpcEndpoints.json"
echo "${NETWORK_ACLS_JSON}" > "${TEMP_JSON_DIR}/networkAcls.json"
echo "${DHCP_OPTIONS_JSON}" > "${TEMP_JSON_DIR}/dhcpOptions.json"
echo "${VPC_PEERINGS_JSON}" > "${TEMP_JSON_DIR}/vpcPeerings.json"
echo "${S3_BUCKETS_JSON}" > "${TEMP_JSON_DIR}/s3Buckets.json"
echo "${KMS_KEYS_JSON}" > "${TEMP_JSON_DIR}/kmsKeys.json"
echo "${IAM_ROLES_JSON}" > "${TEMP_JSON_DIR}/iamRoles.json"
echo "${IAM_PROFILES_JSON}" > "${TEMP_JSON_DIR}/iamProfiles.json"
echo "${HOSTED_ZONES_JSON}" > "${TEMP_JSON_DIR}/hostedZones.json"

# Combine using slurpfile to read from files
jq -n \
    --slurpfile instances "${TEMP_JSON_DIR}/instances.json" \
    --slurpfile volumes "${TEMP_JSON_DIR}/volumes.json" \
    --slurpfile vpcs "${TEMP_JSON_DIR}/vpcs.json" \
    --slurpfile subnets "${TEMP_JSON_DIR}/subnets.json" \
    --slurpfile securityGroups "${TEMP_JSON_DIR}/securityGroups.json" \
    --slurpfile loadBalancers "${TEMP_JSON_DIR}/loadBalancers.json" \
    --slurpfile loadBalancersV2 "${TEMP_JSON_DIR}/loadBalancersV2.json" \
    --slurpfile targetGroups "${TEMP_JSON_DIR}/targetGroups.json" \
    --slurpfile routeTables "${TEMP_JSON_DIR}/routeTables.json" \
    --slurpfile internetGateways "${TEMP_JSON_DIR}/internetGateways.json" \
    --slurpfile natGateways "${TEMP_JSON_DIR}/natGateways.json" \
    --slurpfile elasticIps "${TEMP_JSON_DIR}/elasticIps.json" \
    --slurpfile networkInterfaces "${TEMP_JSON_DIR}/networkInterfaces.json" \
    --slurpfile vpcEndpoints "${TEMP_JSON_DIR}/vpcEndpoints.json" \
    --slurpfile networkAcls "${TEMP_JSON_DIR}/networkAcls.json" \
    --slurpfile dhcpOptions "${TEMP_JSON_DIR}/dhcpOptions.json" \
    --slurpfile vpcPeerings "${TEMP_JSON_DIR}/vpcPeerings.json" \
    --slurpfile s3Buckets "${TEMP_JSON_DIR}/s3Buckets.json" \
    --slurpfile kmsKeys "${TEMP_JSON_DIR}/kmsKeys.json" \
    --slurpfile iamRoles "${TEMP_JSON_DIR}/iamRoles.json" \
    --slurpfile iamProfiles "${TEMP_JSON_DIR}/iamProfiles.json" \
    --slurpfile hostedZones "${TEMP_JSON_DIR}/hostedZones.json" \
    '{
        Instances: $instances[0],
        Volumes: $volumes[0],
        VPCs: $vpcs[0],
        Subnets: $subnets[0],
        SecurityGroups: $securityGroups[0],
        LoadBalancers: $loadBalancers[0],
        LoadBalancersV2: $loadBalancersV2[0],
        TargetGroups: $targetGroups[0],
        RouteTables: $routeTables[0],
        InternetGateways: $internetGateways[0],
        NatGateways: $natGateways[0],
        ElasticIps: $elasticIps[0],
        NetworkInterfaces: $networkInterfaces[0],
        VpcEndpoints: $vpcEndpoints[0],
        NetworkAcls: $networkAcls[0],
        DhcpOptions: $dhcpOptions[0],
        VpcPeerings: $vpcPeerings[0],
        S3Buckets: $s3Buckets[0],
        KmsKeys: $kmsKeys[0],
        IamRoles: $iamRoles[0],
        IamProfiles: $iamProfiles[0],
        HostedZones: $hostedZones[0]
    }' > "${JSON_FILE}"

echo "Raw JSON written to ${JSON_FILE}"

# Parse JSON into human-readable summary
{
    echo "============================================"
    echo "AWS Cluster Resource Summary"
    echo "Infra ID:       ${INFRA_ID}"
    echo "Region:         ${AWS_REGION}"
    echo "Timestamp:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "============================================"
    echo ""

    # Resource counts by type
    echo "--- Resource Inventory ---"
    echo "  Instances:          $(jq '.Instances | length' "${JSON_FILE}")"
    echo "  Volumes:            $(jq '.Volumes | length' "${JSON_FILE}")"
    echo "  VPCs:               $(jq '.VPCs | length' "${JSON_FILE}")"
    echo "  Subnets:            $(jq '.Subnets | length' "${JSON_FILE}")"
    echo "  Security Groups:    $(jq '.SecurityGroups | length' "${JSON_FILE}")"
    echo "  Load Balancers:     $(jq '.LoadBalancers | length' "${JSON_FILE}")"
    echo "  Load Balancers V2:  $(jq '.LoadBalancersV2 | length' "${JSON_FILE}")"
    echo "  Target Groups:      $(jq '.TargetGroups | length' "${JSON_FILE}")"
    echo "  Route Tables:       $(jq '.RouteTables | length' "${JSON_FILE}")"
    echo "  Internet Gateways:  $(jq '.InternetGateways | length' "${JSON_FILE}")"
    echo "  NAT Gateways:       $(jq '.NatGateways | length' "${JSON_FILE}")"
    echo "  Elastic IPs:        $(jq '.ElasticIps | length' "${JSON_FILE}")"
    echo "  Network Interfaces: $(jq '.NetworkInterfaces | length' "${JSON_FILE}")"
    echo "  VPC Endpoints:      $(jq '.VpcEndpoints | length' "${JSON_FILE}")"
    echo "  Network ACLs:       $(jq '.NetworkAcls | length' "${JSON_FILE}")"
    echo "  DHCP Option Sets:   $(jq '.DhcpOptions | length' "${JSON_FILE}")"
    echo "  VPC Peerings:       $(jq '.VpcPeerings | length' "${JSON_FILE}")"
    echo "  S3 Buckets:         $(jq '.S3Buckets | length' "${JSON_FILE}")"
    echo "  KMS Keys:           $(jq '.KmsKeys | length' "${JSON_FILE}")"
    echo "  IAM Roles:          $(jq '.IamRoles | length' "${JSON_FILE}")"
    echo "  IAM Profiles:       $(jq '.IamProfiles | length' "${JSON_FILE}")"
    echo "  Route53 Zones:      $(jq '.HostedZones | length' "${JSON_FILE}")"
    echo ""

    # EC2 Instances
    echo "--- EC2 Instances ---"
    jq -r '
      .Instances[] |
      . as $inst |
      "  \(.InstanceId)  \(.InstanceType)  state=\(.State.Name)  az=\(.Placement.AvailabilityZone)
    privateIP=\(.PrivateIpAddress // "none")  publicIP=\(if .PublicIpAddress then "REDACTED" else "none" end)
    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")
    RootVolume: \(.RootDeviceName)  \((.BlockDeviceMappings[] | select(.DeviceName == $inst.RootDeviceName) | "volumeId=\(.Ebs.VolumeId)  deleteOnTerm=\(.Ebs.DeleteOnTermination)") // "N/A")
    VirtualizationType=\(.VirtualizationType)  Architecture=\(.Architecture)  CpuOptions: coreCount=\(.CpuOptions.CoreCount)  threadsPerCore=\(.CpuOptions.ThreadsPerCore)  nestedVirtualization=\(.CpuOptions.NestedVirtualization // "N/A")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # EBS Volumes
    echo "--- EBS Volumes ---"
    jq -r '
      .Volumes[] |
      "  \(.VolumeId)  size=\(.Size)GB  type=\(.VolumeType)  state=\(.State)  az=\(.AvailabilityZone)
    iops=\(.Iops // "default")  throughput=\(.Throughput // "default")  encrypted=\(.Encrypted)
    attachments: \(if (.Attachments | length) > 0 then (.Attachments | map("\(.InstanceId):\(.Device)  deleteOnTerm=\(.DeleteOnTermination)") | join(", ")) else "none" end)"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # VPCs
    echo "--- VPCs ---"
    jq -r '
      .VPCs[] |
      "  \(.VpcId)  cidr=\(.CidrBlock)  state=\(.State)  tenancy=\(.InstanceTenancy)
    enableDnsSupport=\(.EnableDnsSupport // "unknown")  enableDnsHostnames=\(.EnableDnsHostnames // "unknown")
    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Subnets
    echo "--- Subnets ---"
    jq -r '
      .Subnets[] |
      "  \(.SubnetId)  cidr=\(.CidrBlock)  az=\(.AvailabilityZone)  vpc=\(.VpcId)
    availableIPs=\(.AvailableIpAddressCount)  mapPublicIP=\(.MapPublicIpOnLaunch)
    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Security Groups
    echo "--- Security Groups ---"
    jq -r '
      .SecurityGroups[] |
      "  \(.GroupId)  \(.GroupName)  vpc=\(.VpcId)
    Description: \(.Description)
    IngressRules=\(.IpPermissions | length)  EgressRules=\(.IpPermissionsEgress | length)
\(
  if (.IpPermissions | length) > 0 then
    "    Ingress:\n" + (
      .IpPermissions | map(
        "      \(.IpProtocol) port=\(if .FromPort then "\(.FromPort)-\(.ToPort)" else "all" end) from=\(
          if (.IpRanges | length) > 0 then
            (.IpRanges | map(.CidrIp) | join(","))
          elif (.UserIdGroupPairs | length) > 0 then
            (.UserIdGroupPairs | map(.GroupId) | join(","))
          else
            "all"
          end
        )"
      ) | join("\n")
    )
  else
    ""
  end
)
\(
  if (.IpPermissionsEgress | length) > 0 then
    "    Egress:\n" + (
      .IpPermissionsEgress | map(
        "      \(.IpProtocol) port=\(if .FromPort then "\(.FromPort)-\(.ToPort)" else "all" end) to=\(
          if (.IpRanges | length) > 0 then
            (.IpRanges | map(.CidrIp) | join(","))
          elif (.UserIdGroupPairs | length) > 0 then
            (.UserIdGroupPairs | map(.GroupId) | join(","))
          else
            "all"
          end
        )"
      ) | join("\n")
    )
  else
    ""
  end
)"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Classic Load Balancers
    echo "--- Classic Load Balancers ---"
    jq -r '
      .LoadBalancers[] |
      "  \(.LoadBalancerName)  dns=\(.DNSName)
    scheme=\(.Scheme)  vpc=\(.VPCId // "classic")
    subnets: \(.Subnets // [] | join(", "))
    azs: \(.AvailabilityZones // [] | join(", "))
    listeners: \(.ListenerDescriptions | map("\(.Listener.Protocol):\(.Listener.LoadBalancerPort)->\(.Listener.InstancePort)") | join(", "))"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Application/Network Load Balancers
    echo "--- Application/Network Load Balancers ---"
    jq -r '
      .LoadBalancersV2[] |
      "  \(.LoadBalancerName)  type=\(.Type)  dns=\(.DNSName)
    scheme=\(.Scheme)  vpc=\(.VpcId)
    state=\(.State.Code)  ipAddressType=\(.IpAddressType)
    azs: \(.AvailabilityZones | map("\(.ZoneName) (\(.SubnetId))") | join(", "))"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Target Groups
    echo "--- Target Groups ---"
    jq -r '
      .TargetGroups[] |
      "  \(.TargetGroupName)  protocol=\(.Protocol)  port=\(.Port)  vpc=\(.VpcId)
    healthCheck: \(.HealthCheckProtocol):\(.HealthCheckPort)  path=\(.HealthCheckPath // "N/A")
    targets: \(.LoadBalancerArns | length) LBs"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Route Tables
    echo "--- Route Tables ---"
    jq -r '
      .RouteTables[] |
      "  \(.RouteTableId)  vpc=\(.VpcId)  routes=\(.Routes | length)
    associations: \((.Associations | length) // 0) subnets
    Routes:
\(.Routes | map("      dest=\(.DestinationCidrBlock // .DestinationIpv6CidrBlock // "unknown")  target=\(.GatewayId // .NatGatewayId // .NetworkInterfaceId // .InstanceId // "local")  state=\(.State // "active")") | join("\n"))"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Internet Gateways
    echo "--- Internet Gateways ---"
    jq -r '
      .InternetGateways[] |
      "  \(.InternetGatewayId)
    attachments: \(.Attachments | map("vpc=\(.VpcId)  state=\(.State)") | join(", "))
    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # NAT Gateways
    echo "--- NAT Gateways ---"
    jq -r '
      .NatGateways[] |
      "  \(.NatGatewayId)  state=\(.State)  subnet=\(.SubnetId)  vpc=\(.VpcId)
    privateIP=\(.NatGatewayAddresses[0].PrivateIp // "none")  publicIP=\(if .NatGatewayAddresses[0].PublicIp then "REDACTED" else "none" end)
    connectivityType=\(.ConnectivityType // "public")
    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Elastic IPs
    echo "--- Elastic IPs ---"
    jq -r '
      .ElasticIps[] |
      "  \(.AllocationId)  publicIP=\(if .PublicIp then "REDACTED" else "none" end)  domain=\(.Domain)
    associatedWith: \(.NetworkInterfaceId // .InstanceId // "none")
    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Network Interfaces
    echo "--- Network Interfaces ---"
    jq -r '
      .NetworkInterfaces[] |
      "  \(.NetworkInterfaceId)  type=\(.InterfaceType)  status=\(.Status)  subnet=\(.SubnetId)
    privateIP=\(.PrivateIpAddress)  attachment=\(.Attachment.InstanceId // "none")
    securityGroups: \(.Groups | map(.GroupId) | join(", "))
    Description: \(.Description // "none")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # VPC Endpoints
    echo "--- VPC Endpoints ---"
    jq -r '
      .VpcEndpoints[] |
      "  \(.VpcEndpointId)  type=\(.VpcEndpointType)  service=\(.ServiceName)
    vpc=\(.VpcId)  state=\(.State)
    subnets: \(.SubnetIds // [] | join(", "))"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Network ACLs
    echo "--- Network ACLs ---"
    jq -r '
      .NetworkAcls[] |
      "  \(.NetworkAclId)  vpc=\(.VpcId)  default=\(.IsDefault)
    associations: \(.Associations | length) subnets
    entries: \(.Entries | length) rules"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # DHCP Option Sets
    echo "--- DHCP Option Sets ---"
    jq -r '
      .DhcpOptions[] |
      "  \(.DhcpOptionsId)
    options: \(.DhcpConfigurations | map("\(.Key)=\(.Values | map(.Value) | join(","))") | join("  "))"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # VPC Peering Connections
    echo "--- VPC Peering Connections ---"
    jq -r '
      .VpcPeerings[] |
      "  \(.VpcPeeringConnectionId)  status=\(.Status.Code)
    requester: \(.RequesterVpcInfo.VpcId)  \(.RequesterVpcInfo.CidrBlock)
    accepter: \(.AccepterVpcInfo.VpcId)  \(.AccepterVpcInfo.CidrBlock)"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # S3 Buckets
    echo "--- S3 Buckets ---"
    jq -r '
      .S3Buckets[] |
      "  \(.BucketName)  region=\(.Location // "us-east-1")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # KMS Keys
    echo "--- KMS Keys ---"
    jq -r '
      .KmsKeys[] |
      "  \(.KeyId)  state=\(.KeyState)  origin=\(.Origin)
    description: \(.Description // "none")
    enabled=\(.Enabled)  keyManager=\(.KeyManager)"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # IAM Roles
    echo "--- IAM Roles ---"
    jq -r '
      .IamRoles[] |
      "  \(.RoleName)  roleId=\(.RoleId)
    path=\(.Path)  created=\(.CreateDate)
    description: \(.Description // "none")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # IAM Instance Profiles
    echo "--- IAM Instance Profiles ---"
    jq -r '
      .IamProfiles[] |
      "  \(.InstanceProfileName)  profileId=\(.InstanceProfileId)
    path=\(.Path)  created=\(.CreateDate)
    roles: \(.Roles | map(.RoleName) | join(", "))"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    # Route53 Hosted Zones
    echo "--- Route53 Hosted Zones ---"
    jq -r '
      .HostedZones[] |
      "  \(.Id)  name=\(.Name)  private=\(.Config.PrivateZone // false)
    recordSets=\(.ResourceRecordSetCount // "unknown")"
    ' "${JSON_FILE}" || echo "  (none)"
    echo ""

    echo "============================================"
    echo "Summary complete"
    echo "============================================"

} > "${SUMMARY_FILE}" 2>&1

# Copy the output file to a shared directory so that it can be read by later Steps
cp "${ARTIFACT_DIR}/aws-cluster-describe.json" "${SHARED_DIR}/aws-cluster-describe.json"

echo "Summary written to ${SUMMARY_FILE}"
