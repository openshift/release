#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PS4='+ $(date "+%T.%N") \011'

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${EC2_REGION:-$LEASED_RESOURCE}"
JOB_NAME="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${JOB_NAME}"
cf_tpl_file="${SHARED_DIR}/${JOB_NAME}-cf-tpl.yaml"

ami_id=${EC2_AMI}
instance_type=${EC2_INSTANCE_TYPE}

function log() {
  # Keep logs readable even with `set -x` enabled.
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

function save_stack_events_to_artifacts()
{
  set +o errexit
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json \
    > "${ARTIFACT_DIR}/stack-events-${stack_name}.json" 2>/dev/null
  set -o errexit
}

function stack_status() {
  aws --region "${REGION}" cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true
}

function available_azs_in_region() {
  aws --region "${REGION}" ec2 describe-availability-zones \
    --filters Name=state,Values=available Name=zone-type,Values=availability-zone \
    --query 'AvailabilityZones[].ZoneName' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true
}

function offered_azs_for_instance_type() {
  aws --region "${REGION}" ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters Name=instance-type,Values="${instance_type}" \
    --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null | tr '\t' '\n' | sort -u || true
}

function az_candidates() {
  # Order:
  # - If EC2_AZS is set (comma/space separated): use it verbatim.
  # - Else: intersect "available AZs" with "AZs offering the instance type" (best-effort).
  # - Else: fall back to all available AZs in the region.
  local raw="${EC2_AZS:-}"
  if [[ -n "${raw}" ]]; then
    echo "${raw}" | tr ', ' '\n' | sed '/^$/d' | sort -u
    return 0
  fi

  local avail offered
  avail="$(available_azs_in_region)"
  offered="$(offered_azs_for_instance_type)"

  if [[ -n "${offered}" ]]; then
    # Intersection (keep stable-ish ordering by scanning `avail`).
    local -A offered_set=()
    local z
    while IFS= read -r z; do
      [[ -n "${z}" ]] && offered_set["${z}"]=1
    done <<< "${offered}"
    while IFS= read -r z; do
      [[ -n "${z}" && -n "${offered_set[${z}]+x}" ]] && echo "${z}"
    done <<< "${avail}"
    return 0
  fi

  echo "${avail}"
}

function dump_stack_failure() {
  local name="$1"

  echo "==== CloudFormation failure details for stack ${name} ===="
  aws --region "${REGION}" cloudformation describe-stacks --stack-name "${name}" \
    --query 'Stacks[0].[StackStatus,StackStatusReason]' --output table 2>/dev/null || true
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${name}" \
    --query 'StackEvents[0:40].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]' \
    --output table 2>/dev/null || true
}

function force_cleanup_stack_resources() {

  # Best-effort cleanup for resources that most commonly block stack deletion (DELETE_FAILED).
  # We intentionally keep this minimal (terminate instance) to avoid complex dependency handling.
  local name="$1"

  local instance_id
  instance_id="$(aws --region "${REGION}" cloudformation describe-stack-resources --stack-name "${name}" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' --output text 2>/dev/null || true)"

  if [[ -n "${instance_id}" && "${instance_id}" != "None" ]]; then
    echo "Attempting to terminate instance blocking stack deletion: ${instance_id}"
    aws --region "${REGION}" ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null 2>&1 || true
    aws --region "${REGION}" ec2 wait instance-terminated --instance-ids "${instance_id}" >/dev/null 2>&1 || true
  fi

}

function delete_stack_and_wait() {

  # Returns 0 if the stack disappears, 1 otherwise.
  local name="$1"
  local force_cleanup_done=0
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${name}" >/dev/null 2>&1 || true

  # Poll because waiters are brittle (and we want to branch on DELETE_FAILED).
  for _ in $(seq 1 180); do # up to ~30m
    local st
    st="$(stack_status "${name}")"
    if [[ -z "${st}" || "${st}" == "None" ]]; then
      return 0
    fi

    if [[ "${st}" == "DELETE_FAILED" ]]; then
      echo "Stack deletion failed (DELETE_FAILED): ${name}"
      dump_stack_failure "${name}"

      if [[ "${force_cleanup_done}" -eq 0 ]]; then
        force_cleanup_done=1
        force_cleanup_stack_resources "${name}"
        aws --region "${REGION}" cloudformation delete-stack --stack-name "${name}" >/dev/null 2>&1 || true
      else
        return 1
      fi
    fi

    sleep 10
  done

  echo "Timed out waiting for stack deletion: ${name}"
  dump_stack_failure "${name}"
  return 1

}

function instance_create_failed_reason() {
  # Returns the most recent CREATE_FAILED reason for RHELInstance (best-effort).
  local name="$1"
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${name}" \
    --query "StackEvents[?LogicalResourceId=='RHELInstance' && ResourceStatus=='CREATE_FAILED']|[0].ResourceStatusReason" \
    --output text 2>/dev/null || true
}

function is_insufficient_capacity_failure() {
  local reason="${1:-}"
  [[ "${reason}" == *"do not have sufficient"* ]] || [[ "${reason}" == *"Insufficient"* ]] || [[ "${reason}" == *"capacity"* ]]
}

echo "ec2-user" > "${SHARED_DIR}/ssh_user"

echo -e "AMI ID: $ami_id"

# shellcheck disable=SC2154
cat > "${cf_tpl_file}" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for RHEL machine Launch
Conditions:
  AddSecondaryVolume: !Not [!Equals [!Ref EC2Type, 'MetalMachine']]
Mappings:
 VolumeSize:
   MetalMachine:
     PrimaryVolumeSize: "500"
     SecondaryVolumeSize: "0"
     Throughput: 500
   VirtualMachine:
     PrimaryVolumeSize: "400"
     SecondaryVolumeSize: "10"
     Throughput: 125
Parameters:
  EC2Type:
    Default: 'MetalMachine'
    Type: String
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.192.0.0/16
    Description: CIDR block for VPC.
    Type: String
  PublicSubnetCidr:
    Description: Please enter the IP range (CIDR notation) for the public subnet in the first Availability Zone
    Type: String
    Default: 10.192.10.0/24
  AmiId:
    Description: Current RHEL AMI to use.
    Type: AWS::EC2::Image::Id
  Machinename:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Machinename
    Description: Machinename
    Type: String
    Default: rhel-testbed-ec2-instance
  HostInstanceType:
    Default: t2.medium
    Type: String
  PublicKeyString:
    Type: String
    Description: The public key used to connect to the EC2 instance
  AvailabilityZone:
    Type: String
    Description: Availability Zone to place the VPC subnet/instance into (used for capacity fallback).

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Host Information"
      Parameters:
      - HostInstanceType
      - AvailabilityZone
    - Label:
        default: "Network Configuration"
      Parameters:
      - PublicSubnetCidr
    ParameterLabels:
      PublicSubnetCidr:
        default: "Worker Subnet"
      HostInstanceType:
        default: "Worker Instance Type"
      AvailabilityZone:
        default: "Availability Zone"

Resources:
## VPC Creation

  RHELVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: RHELVPC

## Setup internet access

  RHELInternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: RHELInternetGateway

  RHELGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref RHELVPC
      InternetGatewayId: !Ref RHELInternetGateway

  RHELPublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref RHELVPC
      CidrBlock: !Ref PublicSubnetCidr
      AvailabilityZone: !Ref AvailabilityZone
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: RHELPublicSubnet

  RHELRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref RHELVPC
      Tags:
        - Key: Name
          Value: RHELRouteTable

  RHELPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: RHELGatewayAttachment
    Properties:
      RouteTableId: !Ref RHELRouteTable
      DestinationCidrBlock: "0.0.0.0/0"
      GatewayId: !Ref RHELInternetGateway

  RHELPublicSubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref RHELRouteTable
      SubnetId: !Ref RHELPublicSubnet

## Setup EC2 Roles and security

  RHELIamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "ec2.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"

  RHELInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "RHELIamRole"

  RHELSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: RHEL Host Security Group
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: -1
        ToPort: -1
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5353
        ToPort: 5353
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5678
        ToPort: 5678
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 6443
        ToPort: 6443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      - IpProtocol: udp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      VpcId: !Ref RHELVPC

  rhelLaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateData:
        BlockDeviceMappings:
        - DeviceName: /dev/sda1
          Ebs:
            VolumeSize: !FindInMap [VolumeSize, !Ref EC2Type, PrimaryVolumeSize]
            VolumeType: gp3
            Throughput: !FindInMap [VolumeSize, !Ref EC2Type, Throughput]
        - !If
          - AddSecondaryVolume
          - DeviceName: /dev/sdc
            Ebs:
              VolumeSize: !FindInMap [VolumeSize, !Ref EC2Type, SecondaryVolumeSize]
              VolumeType: gp3
          - !Ref AWS::NoValue

  RHELInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      LaunchTemplate:
        LaunchTemplateId: !Ref rhelLaunchTemplate
        Version: !GetAtt rhelLaunchTemplate.LatestVersionNumber
      IamInstanceProfile: !Ref RHELInstanceProfile
      InstanceType: !Ref HostInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "True"
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt RHELSecurityGroup.GroupId
        SubnetId: !Ref RHELPublicSubnet
      Tags:
      - Key: Name
        Value: !Join ["", [!Ref Machinename]]
      PrivateDnsNameOptions:
        EnableResourceNameDnsARecord: true
        HostnameType: resource-name
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash -xe
          echo "====== Authorizing public key ======" | tee -a /tmp/init_output.txt
          echo "\${PublicKeyString}" >> /home/ec2-user/.ssh/authorized_keys
          # Use the same defaults as OCP to avoid failing requests to apiserver, such as
          # requesting logs.
          echo "====== Updating inotify =====" | tee -a /tmp/init_output.txt
          echo "fs.inotify.max_user_watches = 65536" >> /etc/sysctl.conf
          echo "fs.inotify.max_user_instances = 8192" >> /etc/sysctl.conf
          sysctl --system |& tee -a /tmp/init_output.txt
          sysctl -a |& tee -a /tmp/init_output.txt

Outputs:
  InstanceId:
    Description: RHEL Host Instance ID
    Value: !Ref RHELInstance
  PrivateIp:
    Description: The bastion host Private DNS, will be used for cluster install pulling release image
    Value: !GetAtt RHELInstance.PrivateIp
  PublicIp:
    Description: The bastion host Public IP, will be used for registering minIO server DNS
    Value: !GetAtt RHELInstance.PublicIp
EOF

existing_status="$(stack_status "${stack_name}")"
if [[ -n "${existing_status}" && "${existing_status}" != "None" ]]; then
  echo "Appears that stack ${stack_name} already exists (status: ${existing_status})"
  echo "Deleting stack ${stack_name}"
  if delete_stack_and_wait "${stack_name}"; then
    echo "Deleted stack ${stack_name}"
  else
    echo "Failed to delete pre-existing stack ${stack_name}; refusing to continue to avoid leaking resources."
    exit 1
  fi
fi

echo -e "==== Start to create rhel host ===="
echo "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
# truncate the stack name to 27 characters which is the maximum length of the machine name
machine_name="${stack_name:0:27}"

create_ok=0
selected_az=""

mapfile -t ZONE_CANDIDATES < <(az_candidates)
if [[ "${#ZONE_CANDIDATES[@]}" -eq 0 ]]; then
  echo "No availability zones found for region ${REGION}"
  exit 1
fi

log "Region: ${REGION}; instance_type: ${instance_type}; AZ candidates: ${ZONE_CANDIDATES[*]}"

declare -a ATTEMPTED_AZS=()
declare -a ATTEMPT_REASONS=()

for az in "${ZONE_CANDIDATES[@]}"; do
  log "Creating stack in AZ ${az}: ${stack_name}"

  aws --region "${REGION}" cloudformation create-stack --stack-name "${stack_name}" \
    --template-body "file://${cf_tpl_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
      ParameterKey=HostInstanceType,ParameterValue="${instance_type}" \
      ParameterKey=Machinename,ParameterValue="${machine_name}" \
      ParameterKey=AmiId,ParameterValue="${ami_id}" \
      ParameterKey=PublicKeyString,ParameterValue="$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")" \
      ParameterKey=AvailabilityZone,ParameterValue="${az}"

  if aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" >/dev/null 2>&1; then
    create_ok=1
    selected_az="${az}"
    break
  fi

  status_now="$(stack_status "${stack_name}")"
  reason="$(instance_create_failed_reason "${stack_name}")"
  log "Stack create failed in ${az} (status: ${status_now}; reason: ${reason:-unknown})"
  ATTEMPTED_AZS+=("${az}")
  ATTEMPT_REASONS+=("${reason:-unknown}")

  if is_insufficient_capacity_failure "${reason}"; then
    # Expected transient for metal: try next AZ.
    delete_stack_and_wait "${stack_name}" || true
    sleep 15
    continue
  fi

  # Unexpected failure: dump once and stop trying.
  dump_stack_failure "${stack_name}"
  delete_stack_and_wait "${stack_name}" || true
  break
done

if [[ "${create_ok}" -ne 1 ]]; then
  echo "Failed to create CloudFormation stack: ${stack_name}"
  if [[ "${#ATTEMPTED_AZS[@]}" -gt 0 ]]; then
    echo "Tried AZs:"
    for i in "${!ATTEMPTED_AZS[@]}"; do
      echo "  - ${ATTEMPTED_AZS[$i]}: ${ATTEMPT_REASONS[$i]}"
    done
  fi
  # Dump details once for the last attempt if the stack still exists.
  status_now="$(stack_status "${stack_name}")"
  if [[ -n "${status_now}" && "${status_now}" != "None" ]]; then
    dump_stack_failure "${stack_name}"
  fi
  exit 1
fi

echo "Waited for stack"

echo "$stack_name" > "${SHARED_DIR}/rhel_host_stack_name"
echo "${selected_az}" > "${SHARED_DIR}/aws-availability-zone"
# shellcheck disable=SC2016
INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
--query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-id"
# shellcheck disable=SC2016
HOST_PUBLIC_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicIp`].OutputValue' --output text)"
# shellcheck disable=SC2016
HOST_PRIVATE_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateIp`].OutputValue' --output text)"

echo "${HOST_PUBLIC_IP}" > "${SHARED_DIR}/public_address"
echo "${HOST_PRIVATE_IP}" > "${SHARED_DIR}/private_address"

echo "Waiting up to 5 min for RHEL host to be available"
timeout 5m aws --region "${REGION}" ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}"
