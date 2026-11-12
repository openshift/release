#!/usr/bin/env bash
# Describe AWS Cluster resources which were created by a previous install.
#
# This script queries AWS directly and outputs resource information to a shared file.

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
echo "Describing all AWS resources for cluster: ${INFRA_ID}"

JSON_FILE="${ARTIFACT_DIR}/aws-cluster-describe.json"
SUMMARY_FILE="${ARTIFACT_DIR}/aws-cluster-describe.log"

echo "Querying EC2 instances..."
INSTANCES_JSON=$(aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
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

VOLUMES_JSON=$(aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '.Volumes' 2>/dev/null) || VOLUMES_JSON="[]"

VPCS_JSON=$(aws ec2 describe-vpcs \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '.Vpcs' 2>/dev/null) || VPCS_JSON="[]"

SUBNETS_JSON=$(aws ec2 describe-subnets \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '.Subnets' 2>/dev/null) || SUBNETS_JSON="[]"

SECURITY_GROUPS_JSON=$(aws ec2 describe-security-groups \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '.SecurityGroups' 2>/dev/null) || SECURITY_GROUPS_JSON="[]"

LOAD_BALANCERS_JSON=$(aws elb describe-load-balancers --output json 2>/dev/null | \
    jq --arg infra "${INFRA_ID}" '[.LoadBalancerDescriptions[] | select(.LoadBalancerName | contains($infra))]' 2>/dev/null) || LOAD_BALANCERS_JSON="[]"

LOAD_BALANCERS_V2_JSON=$(aws elbv2 describe-load-balancers --output json 2>/dev/null | \
    jq --arg infra "${INFRA_ID}" '[.LoadBalancers[] | select(.LoadBalancerName | contains($infra))]' 2>/dev/null) || LOAD_BALANCERS_V2_JSON="[]"

ROUTE_TABLES_JSON=$(aws ec2 describe-route-tables \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '.RouteTables' 2>/dev/null) || ROUTE_TABLES_JSON="[]"

INTERNET_GATEWAYS_JSON=$(aws ec2 describe-internet-gateways \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '.InternetGateways' 2>/dev/null) || INTERNET_GATEWAYS_JSON="[]"

NAT_GATEWAYS_JSON=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --output json 2>/dev/null | jq '[.NatGateways[] | .NatGatewayAddresses |= map(if .PublicIp then .PublicIp = "REDACTED" else . end)]' 2>/dev/null) || NAT_GATEWAYS_JSON="[]"

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
    jq -r '.Instances[] |
        . as $inst |
        "  \(.InstanceId)  \(.InstanceType)  state=\(.State.Name)  az=\(.Placement.AvailabilityZone)\n    privateIP=\(.PrivateIpAddress // "none")  publicIP=\(if .PublicIpAddress then "REDACTED" else "none" end)\n    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")\n    RootVolume: \(.RootDeviceName)  \((.BlockDeviceMappings[] | select(.DeviceName == $inst.RootDeviceName) | "volumeId=\(.Ebs.VolumeId)  deleteOnTerm=\(.Ebs.DeleteOnTermination)") // "N/A")\n    VirtualizationType=\(.VirtualizationType)  Architecture=\(.Architecture)  CpuOptions: coreCount=\(.CpuOptions.CoreCount)  threadsPerCore=\(.CpuOptions.ThreadsPerCore)  nestedVirtualization=\(.CpuOptions.NestedVirtualization // "N/A")"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # EBS Volumes
    echo "--- EBS Volumes ---"
    jq -r '.Volumes[] |
        "  \(.VolumeId)  size=\(.Size)GB  type=\(.VolumeType)  state=\(.State)  az=\(.AvailabilityZone)\n    iops=\(.Iops // "default")  throughput=\(.Throughput // "default")  encrypted=\(.Encrypted)\n    attachments: \(if (.Attachments | length) > 0 then (.Attachments | map("\(.InstanceId):\(.Device)  deleteOnTerm=\(.DeleteOnTermination)") | join(", ")) else "none" end)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # VPCs
    echo "--- VPCs ---"
    jq -r '.VPCs[] |
        "  \(.VpcId)  cidr=\(.CidrBlock)  state=\(.State)  tenancy=\(.InstanceTenancy)\n    enableDnsSupport=\(.EnableDnsSupport // "unknown")  enableDnsHostnames=\(.EnableDnsHostnames // "unknown")\n    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # Subnets
    echo "--- Subnets ---"
    jq -r '.Subnets[] |
        "  \(.SubnetId)  cidr=\(.CidrBlock)  az=\(.AvailabilityZone)  vpc=\(.VpcId)\n    availableIPs=\(.AvailableIpAddressCount)  mapPublicIP=\(.MapPublicIpOnLaunch)\n    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # Security Groups
    echo "--- Security Groups ---"
    jq -r '.SecurityGroups[] |
        "  \(.GroupId)  \(.GroupName)  vpc=\(.VpcId)\n    Description: \(.Description)\n    IngressRules=\(.IpPermissions | length)  EgressRules=\(.IpPermissionsEgress | length)\n\(if (.IpPermissions | length) > 0 then "    Ingress:\n" + (.IpPermissions | map("      \(.IpProtocol) port=\(if .FromPort then "\(.FromPort)-\(.ToPort)" else "all" end) from=\(if (.IpRanges | length) > 0 then (.IpRanges | map(.CidrIp) | join(",")) elif (.UserIdGroupPairs | length) > 0 then (.UserIdGroupPairs | map(.GroupId) | join(",")) else "all" end)") | join("\n")) else "" end)\n\(if (.IpPermissionsEgress | length) > 0 then "    Egress:\n" + (.IpPermissionsEgress | map("      \(.IpProtocol) port=\(if .FromPort then "\(.FromPort)-\(.ToPort)" else "all" end) to=\(if (.IpRanges | length) > 0 then (.IpRanges | map(.CidrIp) | join(",")) elif (.UserIdGroupPairs | length) > 0 then (.UserIdGroupPairs | map(.GroupId) | join(",")) else "all" end)") | join("\n")) else "" end)"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # Classic Load Balancers
    echo "--- Classic Load Balancers ---"
    jq -r '.LoadBalancers[] |
        "  \(.LoadBalancerName)  dns=\(.DNSName)\n    scheme=\(.Scheme)  vpc=\(.VPCId // "classic")\n    subnets: \(.Subnets // [] | join(", "))\n    azs: \(.AvailabilityZones // [] | join(", "))\n    listeners: \(.ListenerDescriptions | map("\(.Listener.Protocol):\(.Listener.LoadBalancerPort)->\(.Listener.InstancePort)") | join(", "))"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # Application/Network Load Balancers
    echo "--- Application/Network Load Balancers ---"
    jq -r '.LoadBalancersV2[] |
        "  \(.LoadBalancerName)  type=\(.Type)  dns=\(.DNSName)\n    scheme=\(.Scheme)  vpc=\(.VpcId)\n    state=\(.State.Code)  ipAddressType=\(.IpAddressType)\n    azs: \(.AvailabilityZones | map("\(.ZoneName) (\(.SubnetId))") | join(", "))"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # Route Tables
    echo "--- Route Tables ---"
    jq -r '.RouteTables[] |
        "  \(.RouteTableId)  vpc=\(.VpcId)  routes=\(.Routes | length)\n    associations: \((.Associations | length) // 0) subnets\n    Routes:\n\(.Routes | map("      dest=\(.DestinationCidrBlock // .DestinationIpv6CidrBlock // "unknown")  target=\(.GatewayId // .NatGatewayId // .NetworkInterfaceId // .InstanceId // "local")  state=\(.State // "active")") | join("\n"))"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # Internet Gateways
    echo "--- Internet Gateways ---"
    jq -r '.InternetGateways[] |
        "  \(.InternetGatewayId)\n    attachments: \(.Attachments | map("vpc=\(.VpcId)  state=\(.State)") | join(", "))\n    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    # NAT Gateways
    echo "--- NAT Gateways ---"
    jq -r '.NatGateways[] |
        "  \(.NatGatewayId)  state=\(.State)  subnet=\(.SubnetId)  vpc=\(.VpcId)\n    privateIP=\(.NatGatewayAddresses[0].PrivateIp // "none")  publicIP=\(if .NatGatewayAddresses[0].PublicIp then "REDACTED" else "none" end)\n    connectivityType=\(.ConnectivityType // "public")\n    Name=\((.Tags // [] | map(select(.Key == "Name") | .Value) | .[0]) // "untagged")"' "${JSON_FILE}" \
        || echo "  (none)"
    echo ""

    echo "============================================"
    echo "Summary complete"
    echo "============================================"

} > "${SUMMARY_FILE}" 2>&1

# Copy the output file to a shared directory so that it can be read by later Steps
cp "${ARTIFACT_DIR}/aws-cluster-describe.json" "${SHARED_DIR}/aws-cluster-describe.json"

echo "Summary written to ${SUMMARY_FILE}"
