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
echo "Querying all tagged resources via Resource Groups Tagging API..."
TAGGED_RESOURCES=$(aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq -r '.ResourceTagMappingList[] | .ResourceARN' 2>/dev/null) || TAGGED_RESOURCES=""

if [[ -z "${TAGGED_RESOURCES}" ]]; then
  echo "WARNING: No resources found with tag kubernetes.io/cluster/${INFRA_ID}=owned"
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

# Query EC2 instances
if [[ -n "${EC2_INSTANCE_IDS}" ]]; then
  echo "Fetching EC2 instance details..."
  INSTANCES_JSON=$(aws ec2 describe-instances \
      --instance-ids ${EC2_INSTANCE_IDS} \
      --output json | jq '[
        .Reservations[].Instances[] |
        if .PublicIpAddress then .PublicIpAddress = "REDACTED" else . end |
        if .NetworkInterfaces then
          .NetworkInterfaces |= map(
            if .Association.PublicIp then .Association.PublicIp = "REDACTED" else . end |
            if .PrivateIpAddresses then
              .PrivateIpAddresses |= map(
                if .Association.PublicIp then .Association.PublicIp = "REDACTED" else . end
              )
            else . end
          )
        else . end
      ]') || INSTANCES_JSON="[]"
else
  INSTANCES_JSON="[]"
fi

# Query EBS volumes
if [[ -n "${VOLUME_IDS}" ]]; then
  echo "Fetching EBS volume details..."
  VOLUMES_JSON=$(aws ec2 describe-volumes \
      --volume-ids ${VOLUME_IDS} \
      --output json | jq '.Volumes') || VOLUMES_JSON="[]"
else
  VOLUMES_JSON="[]"
fi

# Query VPCs
if [[ -n "${VPC_IDS}" ]]; then
  echo "Fetching VPC details..."
  VPCS_JSON=$(aws ec2 describe-vpcs \
      --vpc-ids ${VPC_IDS} \
      --output json | jq '.Vpcs') || VPCS_JSON="[]"
else
  VPCS_JSON="[]"
fi

# Query Subnets
if [[ -n "${SUBNET_IDS}" ]]; then
  echo "Fetching subnet details..."
  SUBNETS_JSON=$(aws ec2 describe-subnets \
      --subnet-ids ${SUBNET_IDS} \
      --output json | jq '.Subnets') || SUBNETS_JSON="[]"
else
  SUBNETS_JSON="[]"
fi

# Query Security Groups
if [[ -n "${SG_IDS}" ]]; then
  echo "Fetching security group details..."
  SECURITY_GROUPS_JSON=$(aws ec2 describe-security-groups \
      --group-ids ${SG_IDS} \
      --output json | jq '.SecurityGroups') || SECURITY_GROUPS_JSON="[]"
else
  SECURITY_GROUPS_JSON="[]"
fi

# Query Route Tables
if [[ -n "${RTB_IDS}" ]]; then
  echo "Fetching route table details..."
  ROUTE_TABLES_JSON=$(aws ec2 describe-route-tables \
      --route-table-ids ${RTB_IDS} \
      --output json | jq '.RouteTables') || ROUTE_TABLES_JSON="[]"
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

# Query Load Balancers (Classic) - these may not be directly taggable, so use name matching
echo "Fetching classic load balancers..."
LOAD_BALANCERS_JSON=$(aws elb describe-load-balancers --output json 2>/dev/null | \
    jq --arg infra "${INFRA_ID}" '[
      .LoadBalancerDescriptions[] |
      select(.LoadBalancerName | contains($infra))
    ]') || LOAD_BALANCERS_JSON="[]"

# Query Load Balancers V2 (ALB/NLB) - check tags via ARNs
echo "Fetching application/network load balancers..."
LB_V2_ARNS=$(echo "${TAGGED_RESOURCES}" | grep 'elasticloadbalancing:loadbalancer/' || true)
if [[ -n "${LB_V2_ARNS}" ]]; then
  LOAD_BALANCERS_V2_JSON=$(aws elbv2 describe-load-balancers --output json 2>/dev/null | \
      jq --argjson arns "$(echo "${LB_V2_ARNS}" | jq -R -s 'split("\n") | map(select(length > 0))')" '[
        .LoadBalancers[] |
        select(.LoadBalancerArn as $arn | $arns | index($arn))
      ]') || LOAD_BALANCERS_V2_JSON="[]"
else
  LOAD_BALANCERS_V2_JSON="[]"
fi

# Combine into single JSON
jq -n \
    --argjson instances "${INSTANCES_JSON}" \
    --argjson volumes "${VOLUMES_JSON}" \
    --argjson vpcs "${VPCS_JSON}" \
    --argjson subnets "${SUBNETS_JSON}" \
    --argjson securityGroups "${SECURITY_GROUPS_JSON}" \
    --argjson loadBalancers "${LOAD_BALANCERS_JSON}" \
    --argjson loadBalancersV2 "${LOAD_BALANCERS_V2_JSON}" \
    --argjson routeTables "${ROUTE_TABLES_JSON}" \
    --argjson internetGateways "${INTERNET_GATEWAYS_JSON}" \
    --argjson natGateways "${NAT_GATEWAYS_JSON}" \
    '{
        Instances: $instances,
        Volumes: $volumes,
        VPCs: $vpcs,
        Subnets: $subnets,
        SecurityGroups: $securityGroups,
        LoadBalancers: $loadBalancers,
        LoadBalancersV2: $loadBalancersV2,
        RouteTables: $routeTables,
        InternetGateways: $internetGateways,
        NatGateways: $natGateways
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
    echo "  Route Tables:       $(jq '.RouteTables | length' "${JSON_FILE}")"
    echo "  Internet Gateways:  $(jq '.InternetGateways | length' "${JSON_FILE}")"
    echo "  NAT Gateways:       $(jq '.NatGateways | length' "${JSON_FILE}")"
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

    echo "============================================"
    echo "Summary complete"
    echo "============================================"

} > "${SUMMARY_FILE}" 2>&1

# Copy the output file to a shared directory so that it can be read by later Steps
cp "${ARTIFACT_DIR}/aws-cluster-describe.json" "${SHARED_DIR}/aws-cluster-describe.json"

echo "Summary written to ${SUMMARY_FILE}"
