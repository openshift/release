#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi      
        
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# -----------------------------------------
# OCP-29781 - [ipi-on-aws] Install two clusters in different isolated CIDR in one shared VPC
# -----------------------------------------

trap 'save_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}


# -----------------------------------------
# Create VPC with multi CIDR
# -----------------------------------------


cat > /tmp/01_vpc_multiCidr.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice VPC with 1-3 AZs

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  VpcCidr2:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.134.0.0/16
    Description: CIDR2 block for VPC.
    Type: String
  VpcCidr3:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.190.0.0/16
    Description: CIDR3 block for VPC.
    Type: String
  AvailabilityZoneCount:
    ConstraintDescription: "The number of availability zones. (Min: 1, Max: 3)"
    MinValue: 2
    MaxValue: 3
    Default: 3
    Description: "How many AZs to create VPC subnets for. (Min: 1, Max: 3)"
    Type: Number
  SubnetBits:
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/19-27.
    MinValue: 5
    MaxValue: 13
    Default: 12
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /27, Max: 13 = /19)"
    Type: Number
  DhcpOptionSet:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Description: "Create a dhcpOptionSet with a custom DNS name"
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcCidr
      - SubnetBits
    - Label:
        default: "Availability Zones"
      Parameters:
      - AvailabilityZoneCount
    ParameterLabels:
      AvailabilityZoneCount:
        default: "Availability Zone Count"
      VpcCidr:
        default: "VPC CIDR"
      SubnetBits:
        default: "Bits Per Subnet"

Conditions:
  DoAz3: !Equals [3, !Ref AvailabilityZoneCount]
  DoAz2: !Or [!Equals [2, !Ref AvailabilityZoneCount], Condition: DoAz3]
  DoDhcp: !Equals ["yes", !Ref DhcpOptionSet]

Resources:
  VPC:
    Type: "AWS::EC2::VPC"
    Properties:
      EnableDnsSupport: "true"
      EnableDnsHostnames: "true"
      CidrBlock: !Ref VpcCidr
      Tags:
      - Key: Name
        Value: !Join [ "-", [ !Ref "AWS::StackName", "cf" ] ]
  Cidr2:
    Type: "AWS::EC2::VPCCidrBlock"
    Condition: DoAz2
    Properties:
      CidrBlock: !Ref VpcCidr2
      VpcId: !Ref VPC
  Cidr3:
    Type: "AWS::EC2::VPCCidrBlock"
    Condition: DoAz3
    Properties:
      CidrBlock: !Ref VpcCidr3
      VpcId: !Ref VPC
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      AvailabilityZone: !Select
      - 0
      - Fn::GetAZs: !Ref "AWS::Region"
  PublicSubnet2:
    Type: "AWS::EC2::Subnet"
    DependsOn: Cidr2
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr2, 6, !Ref SubnetBits]]
      AvailabilityZone: !Select
      - 1
      - Fn::GetAZs: !Ref "AWS::Region"
  PublicSubnet3:
    Type: "AWS::EC2::Subnet"
    DependsOn: Cidr3
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr3, 6, !Ref SubnetBits]]
      AvailabilityZone: !Select
      - 2
      - Fn::GetAZs: !Ref "AWS::Region"
  InternetGateway:
    Type: "AWS::EC2::InternetGateway"
  GatewayToInternet:
    Type: "AWS::EC2::VPCGatewayAttachment"
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway
  PublicRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PublicRoute:
    Type: "AWS::EC2::Route"
    DependsOn: GatewayToInternet
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway
  PublicSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTable
  PublicSubnetRouteTableAssociation2:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz2
    Properties:
      SubnetId: !Ref PublicSubnet2
      RouteTableId: !Ref PublicRouteTable
  PublicSubnetRouteTableAssociation3:
    Condition: DoAz3
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet3
      RouteTableId: !Ref PublicRouteTable
  PrivateSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      AvailabilityZone: !Select
      - 0
      - Fn::GetAZs: !Ref "AWS::Region"
  PrivateRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable
  NAT:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP
        - AllocationId
      SubnetId: !Ref PublicSubnet
  EIP:
    Type: "AWS::EC2::EIP"
    Properties:
      Domain: vpc
  Route:
    Type: "AWS::EC2::Route"
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT
  PrivateSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    DependsOn: Cidr2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr2, 6, !Ref SubnetBits]]
      AvailabilityZone: !Select
      - 1
      - Fn::GetAZs: !Ref "AWS::Region"
  PrivateRouteTable2:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation2:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz2
    Properties:
      SubnetId: !Ref PrivateSubnet2
      RouteTableId: !Ref PrivateRouteTable2
  NAT2:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz2
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP2
        - AllocationId
      SubnetId: !Ref PublicSubnet2
  EIP2:
    Type: "AWS::EC2::EIP"
    Condition: DoAz2
    Properties:
      Domain: vpc
  Route2:
    Type: "AWS::EC2::Route"
    Condition: DoAz2
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable2
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT2
  PrivateSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    DependsOn: Cidr3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr3, 6, !Ref SubnetBits]]
      AvailabilityZone: !Select
      - 2
      - Fn::GetAZs: !Ref "AWS::Region"
  PrivateRouteTable3:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation3:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz3
    Properties:
      SubnetId: !Ref PrivateSubnet3
      RouteTableId: !Ref PrivateRouteTable3
  NAT3:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz3
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP3
        - AllocationId
      SubnetId: !Ref PublicSubnet3
  EIP3:
    Type: "AWS::EC2::EIP"
    Condition: DoAz3
    Properties:
      Domain: vpc
  Route3:
    Type: "AWS::EC2::Route"
    Condition: DoAz3
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable3
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT3
  S3Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PolicyDocument:
        Version: 2012-10-17
        Statement:
        - Effect: Allow
          Principal: '*'
          Action:
          - '*'
          Resource:
          - '*'
      RouteTableIds:
      - !Ref PublicRouteTable
      - !Ref PrivateRouteTable
      - !If [DoAz2, !Ref PrivateRouteTable2, !Ref "AWS::NoValue"]
      - !If [DoAz3, !Ref PrivateRouteTable3, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VPC
  DhcpOptions: 
    Type: AWS::EC2::DHCPOptions
    Condition: DoDhcp
    Properties: 
        DomainName: example.com
        DomainNameServers: 
          - AmazonProvidedDNS
  VPCDHCPOptionsAssociation:
    Type: AWS::EC2::VPCDHCPOptionsAssociation
    Condition: DoDhcp
    Properties:
      VpcId: !Ref VPC
      DhcpOptionsId: !Ref DhcpOptions

Outputs:
  VpcId:
    Description: ID of the new VPC.
    Value: !Ref VPC
  PublicSubnetIds:
    Description: Subnet IDs of the public subnets.
    Value:
      !Join [
        ",",
        [!Ref PublicSubnet, !If [DoAz2, !Ref PublicSubnet2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PublicSubnet3, !Ref "AWS::NoValue"]]
      ]
  PrivateSubnetIds:
    Description: Subnet IDs of the private subnets.
    Value:
      !Join [
        ",",
        [!Ref PrivateSubnet, !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PrivateSubnet3, !Ref "AWS::NoValue"]]
      ]
  CIDRs:
    Description: CIDRs.
    Value:
      !Join [
        ",",
        [!Ref VpcCidr, !If [DoAz2, !Ref VpcCidr2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref VpcCidr3, !Ref "AWS::NoValue"]]
      ]
  SubnetsIdsForCidr:
    Description: Subnet IDs for Cidr1, the first is private subnet, the second is public subnet
    Value:
      !Join [
        ",",
        [!Ref PrivateSubnet, !Ref PublicSubnet]
      ]
  SubnetsIdsForCidr2:
    Description: Subnet IDs for Cidr2, the first is private subnet, the second is public subnet
    Value:
      !Join [
        ",",
        [!If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"], !If [DoAz2, !Ref PublicSubnet2, !Ref "AWS::NoValue"]]
      ]
  SubnetsIdsForCidr3:
    Description: Subnet IDs for Cidr3, the first is private subnet, the second is public subnet
    Value:
      !Join [
        ",",
        [!If [DoAz3, !Ref PrivateSubnet3, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PublicSubnet3, !Ref "AWS::NoValue"]]
      ]
EOF

cluster_cidr1="10.134.0.0/16"
cluster_cidr2="10.190.0.0/16"

CLUSTER_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
STACK_NAME="${CLUSTER_PREFIX}-vpc"
echo "${STACK_NAME}" > "${SHARED_DIR}/vpc_stack_name"

EXPIRATION_DATE=$(date -d '6 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_vpc_multiCidr.yaml)" \
  --parameters ParameterKey=VpcCidr2,ParameterValue=${cluster_cidr1} \
               ParameterKey=VpcCidr3,ParameterValue=${cluster_cidr2} \
  --tags "${TAGS}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"


aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/vpc_stack_output"

# -----------------------------------------
# Create install-config
# -----------------------------------------
ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

function create_install_config()
{
  local cluster_name=$1
  local subnet_file=$2
  local machine_cidr=$3
  local install_dir=$4

  cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: ${OCP_ARCH}
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: ${OCP_ARCH}
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: 3
metadata:
  creationTimestamp: null
  name: ${cluster_name}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${machine_cidr}
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
    subnets: $(cat "${subnet_file}")
publish: External
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

  patch=$(mktemp)
  if [[ ${CONTROL_PLANE_INSTANCE_TYPE} != "" ]]; then
    cat > "${patch}" << EOF
controlPlane:
  platform:
    aws:
      type: ${CONTROL_PLANE_INSTANCE_TYPE}
EOF
    yq-go m -x -i ${install_dir}/install-config.yaml "${patch}"
  fi

  if [[ ${COMPUTE_NODE_TYPE} != "" ]]; then
    cat > "${patch}" << EOF
compute:
- platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
EOF
    yq-go m -x -i ${install_dir}/install-config.yaml "${patch}"
  fi
}

# -----------------------------------------
# Create clusters
# -----------------------------------------

cluster_name1="${CLUSTER_PREFIX}1"
cluster_name2="${CLUSTER_PREFIX}2"
install_dir1=/tmp/${cluster_name1}
install_dir2=/tmp/${cluster_name2}

mkdir -p ${install_dir1} 2>/dev/null
mkdir -p ${install_dir2} 2>/dev/null

subnet_file1=/tmp/subnet1
subnet_file2=/tmp/subnet2

# format: 
#  ['subnet-017437c760cf617a0','subnet-01febfaef930e48f1']
jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetsIdsForCidr2")).OutputValue | split(",")[]]' "${SHARED_DIR}/vpc_stack_output" | sed "s/\"/'/g" > ${subnet_file1}
jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetsIdsForCidr3")).OutputValue | split(",")[]]' "${SHARED_DIR}/vpc_stack_output" | sed "s/\"/'/g" > ${subnet_file2}



create_install_config $cluster_name1 ${subnet_file1} "${cluster_cidr1}" $install_dir1
create_install_config $cluster_name2 ${subnet_file2} "${cluster_cidr2}" $install_dir2

function save_artifacts()
{
  set +o errexit
  current_time=$(date +%s)
  aws --region ${REGION} cloudformation describe-stack-events --stack-name ${STACK_NAME} --output json > "${ARTIFACT_DIR}/stack-events-${STACK_NAME}.json"
  cp "${install_dir1}/metadata.json" "${SHARED_DIR}/cluster-1-metadata.json"
  cp "${install_dir2}/metadata.json" "${SHARED_DIR}/cluster-2-metadata.json"

  cp "${install_dir1}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  cp "${install_dir2}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir1}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_1_openshift_install-${current_time}.log"
  
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${install_dir2}/.openshift_install.log" > "${ARTIFACT_DIR}/cluster_2_openshift_install-${current_time}.log"

  
  if [ -d "${install_dir1}/.clusterapi_output" ]; then
    mkdir -p "${ARTIFACT_DIR}/cluster_1_clusterapi_output-${current_time}"
    cp -rpv "${install_dir1}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/cluster_1_clusterapi_output-${current_time}" 2>/dev/null
  fi

  if [ -d "${install_dir2}/.clusterapi_output" ]; then
    mkdir -p "${ARTIFACT_DIR}/cluster_2_clusterapi_output-${current_time}"
    cp -rpv "${install_dir2}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/cluster_2_clusterapi_output-${current_time}" 2>/dev/null
  fi

  set -o errexit
}


echo "Creating cluster 1"
cat ${install_dir1}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/cluster-1-install-config.yaml
openshift-install --dir="${install_dir1}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
ret="$?"
echo "Installer exit with code $ret"

echo "Creating cluster 2"
cat ${install_dir2}/install-config.yaml | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/cluster-2-install-config.yaml
openshift-install --dir="${install_dir2}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
ret="$?"
echo "Installer exit with code $ret"


ret=0

infra_id1=$(jq -r '.infraID' ${install_dir1}/metadata.json)
infra_id2=$(jq -r '.infraID' ${install_dir2}/metadata.json)

sg_info1=${ARTIFACT_DIR}/sg_info1.json
sg_info2=${ARTIFACT_DIR}/sg_info2.json

aws --region $REGION ec2 describe-security-groups --filters "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${infra_id1},Values=owned"  > $sg_info1
aws --region $REGION ec2 describe-security-groups --filters "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${infra_id2},Values=owned"  > $sg_info2

sg_api_lb1=${infra_id1}-apiserver-lb
sg_api_lb2=${infra_id2}-apiserver-lb

sg_cp1=${infra_id1}-controlplane
sg_cp2=${infra_id2}-controlplane



# -------------------------------------------------------------------------------------
# check apiserver-lb sg, expect cidr ip is the same as machine cidr for port 22623
# -------------------------------------------------------------------------------------

# Cluster 1 MCS internal traffic from cluster, expect ${cluster_cidr1}
cidr_ip1=$(cat $sg_info1 | jq --arg sg_api_lb  $sg_api_lb1 -r '.SecurityGroups[] | select(any(.Tags[]; .Key == "Name" and .Value == $sg_api_lb)) | .IpPermissions[] | select(.FromPort==22623 and .ToPort==22623) | .IpRanges[0].CidrIp')

if [ ${cidr_ip1} != "${cluster_cidr1}" ]; then
  echo "Error: cluster 1 apiserver-lb sg: except ${cluster_cidr1} for port 22623, but got ${cidr_ip1}"
  ret=$((ret+1))
else
  echo "Pass: cluster 1 apiserver-lb sg: ${cluster_cidr1} for port 22623"
fi


# Cluster 1 MCS internal traffic from cluster, expect ${cluster_cidr2}
cidr_ip2=$(cat $sg_info2 | jq --arg sg_api_lb  $sg_api_lb2 -r '.SecurityGroups[] | select(any(.Tags[]; .Key == "Name" and .Value == $sg_api_lb)) | .IpPermissions[] | select(.FromPort==22623 and .ToPort==22623) | .IpRanges[0].CidrIp')

if [ ${cidr_ip2} != "${cluster_cidr2}" ]; then
  echo "Error: cluster 2 apiserver-lb sg: except ${cluster_cidr2} for port 22623, but got ${cidr_ip2}"
  ret=$((ret+1))
else
  echo "Pass: cluster 2 apiserver-lb sg: ${cluster_cidr2} for port 22623"
fi

# -------------------------------------------------------------------------------------
# check controlplane sg, expect apiserver-lb sg is attached to it
# -------------------------------------------------------------------------------------

apilb_sg_id1=$(cat $sg_info1 | jq --arg sg_api_lb  $sg_api_lb1 -r '.SecurityGroups[] | select(any(.Tags[]; .Key == "Name" and .Value == $sg_api_lb)) | .GroupId')
t1=$(cat $sg_info1 | jq --arg apilb_sg_id $apilb_sg_id1 --arg sg_cp  $sg_cp1 -r '.SecurityGroups[] | select(any(.Tags[]; .Key == "Name" and .Value == $sg_cp)) | .IpPermissions[] | select(.FromPort==22623 and .ToPort==22623) | .UserIdGroupPairs[] | select(.GroupId==$apilb_sg_id) | .GroupId')

if [[ "$t1" != "$apilb_sg_id1" ]]; then
  echo "Error: cluster 1: apiserver-lb sg was not attached to control plane, please check."
  ret=$((ret+1))
else
  echo "Pass: cluster 1: apiserver-lb sg was attached to control plane."
fi



apilb_sg_id2=$(cat $sg_info2 | jq --arg sg_api_lb  $sg_api_lb2 -r '.SecurityGroups[] | select(any(.Tags[]; .Key == "Name" and .Value == $sg_api_lb)) | .GroupId')
t2=$(cat $sg_info2 | jq --arg apilb_sg_id $apilb_sg_id2 --arg sg_cp  $sg_cp2 -r '.SecurityGroups[] | select(any(.Tags[]; .Key == "Name" and .Value == $sg_cp)) | .IpPermissions[] | select(.FromPort==22623 and .ToPort==22623) | .UserIdGroupPairs[] | select(.GroupId==$apilb_sg_id) | .GroupId')

if [[ "$t2" != "$apilb_sg_id2" ]]; then
  echo "Error: cluster 2: apiserver-lb sg was not attached to control plane, please check."
  ret=$((ret+1))
else
  echo "Pass: cluster 2: apiserver-lb sg was attached to control plane."
fi


# -------------------------------------------------------------------------------------
# health check
# -------------------------------------------------------------------------------------


function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function check_clusteroperators() {
    local tmp_ret=0 tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc null_version unavailable_operator degraded_operator skip_operator

    local skip_operator="aro" # ARO operator versioned but based on RP git commit ID not cluster version

    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    oc get clusteroperator >"${tmp_clusteroperator}"
    column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
    last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
        awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
        input="${tmp_clusteroperator_1}"
    fi

    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done < "${input}"
    rm -f "${tmp_clusteroperator}"

    echo "Make sure every operator column reports version"
    if null_version=$(oc get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
      echo >&2 "Null Version: ${null_version}"
      (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator reports correct version"
    if incorrect_version=$(oc get clusteroperator --no-headers | grep -v ${skip_operator} | awk -v var="${EXPECTED_VERSION}" '$2 != var') && [[ ${incorrect_version} != "" ]]; then
        echo >&2 "Incorrect CO Version: ${incorrect_version}"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's AVAILABLE column is True"
    if unavailable_operator=$(oc get clusteroperator | awk '$3 == "False"' | grep "False"); then
        echo >&2 "Some operator's AVAILABLE is False"
        echo >&2 "$unavailable_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Available") | .status' | grep -iv "True"; then
        echo >&2 "Some operators are not Available, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's PROGRESSING column is False"
    if progressing_operator=$(oc get clusteroperator | awk '$4 == "True"' | grep "True"); then
        echo >&2 "Some operator's PROGRESSING is True"
        echo >&2 "$progressing_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Progressing") | .status' | grep -iv "False"; then
        echo >&2 "Some operators are Progressing, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    echo "Make sure every operator's DEGRADED column is False"
    if degraded_operator=$(oc get clusteroperator | awk '$5 == "True"' | grep "True"); then
        echo >&2 "Some operator's DEGRADED is True"
        echo >&2 "$degraded_operator"
        (( tmp_ret += 1 ))
    fi
    if oc get clusteroperator -o json | jq '.items[].status.conditions[] | select(.type == "Degraded") | .status'  | grep -iv 'False'; then
        echo >&2 "Some operators are Degraded, pls run 'oc get clusteroperator -o json' to check"
        (( tmp_ret += 1 ))
    fi

    return $tmp_ret
}

function wait_clusteroperators_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=3 max_retries=20
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        if check_clusteroperators; then
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        else
            echo "cluster operators are not ready yet, wait and retry..."
            continous_successful_check=0
        fi
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some cluster operator does not get ready or not stable"
        echo "Debug: current CO output is:"
        oc get co
        return 1
    else
        echo "All cluster operators status check PASSED"
        return 0
    fi
}

function check_mcp() {
    local updating_mcp unhealthy_mcp tmp_output

    tmp_output=$(mktemp)
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        updating_mcp=$(cat "${tmp_output}" | grep -v "False")
        if [[ -n "${updating_mcp}" ]]; then
            echo "Some mcp is updating..."
            echo "${updating_mcp}"
            return 1
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi

    # Do not check UPDATED on purpose, beause some paused mcp would not update itself until unpaused
    oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount --no-headers > "${tmp_output}" || true
    # using the size of output to determinate if oc command is executed successfully
    if [[ -s "${tmp_output}" ]]; then
        unhealthy_mcp=$(cat "${tmp_output}" | grep -v "False.*False.*0")
        if [[ -n "${unhealthy_mcp}" ]]; then
            echo "Detected unhealthy mcp:"
            echo "${unhealthy_mcp}"
            echo "Real-time detected unhealthy mcp:"
            oc get machineconfigpools -o custom-columns=NAME:metadata.name,CONFIG:spec.configuration.name,UPDATING:status.conditions[?\(@.type==\"Updating\"\)].status,DEGRADED:status.conditions[?\(@.type==\"Degraded\"\)].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount | grep -v "False.*False.*0"
            echo "Real-time full mcp output:"
            oc get machineconfigpools
            echo ""
            unhealthy_mcp_names=$(echo "${unhealthy_mcp}" | awk '{print $1}')
            echo "Using oc describe to check status of unhealthy mcp ..."
            for mcp_name in ${unhealthy_mcp_names}; do
              echo "Name: $mcp_name"
              oc describe mcp $mcp_name || echo "oc describe mcp $mcp_name failed"
            done
            return 2
        fi
    else
        echo "Did not run 'oc get machineconfigpools' successfully!"
        return 1
    fi
    return 0
}

function wait_mcp_continous_success() {
    local try=0 continous_successful_check=0 passed_criteria=5 max_retries=20 ret=0
    local continous_degraded_check=0 degraded_criteria=5
    while (( try < max_retries && continous_successful_check < passed_criteria )); do
        echo "Checking #${try}"
        ret=0
        check_mcp || ret=$?
        if [[ "$ret" == "0" ]]; then
            continous_degraded_check=0
            echo "Passed #${continous_successful_check}"
            (( continous_successful_check += 1 ))
        elif [[ "$ret" == "1" ]]; then
            echo "Some machines are updating..."
            continous_successful_check=0
            continous_degraded_check=0
        else
            continous_successful_check=0
            echo "Some machines are degraded #${continous_degraded_check}..."
            (( continous_degraded_check += 1 ))
            if (( continous_degraded_check >= degraded_criteria )); then
                break
            fi
        fi
        echo "wait and retry..."
        sleep 60
        (( try += 1 ))
    done
    if (( continous_successful_check != passed_criteria )); then
        echo >&2 "Some mcp does not get ready or not stable"
        echo "Debug: current mcp output is:"
        oc get machineconfigpools
        return 1
    else
        echo "All mcp status check PASSED"
        return 0
    fi
}

function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | wc -l)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node --no-headers | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_pod() {
    local soptted_pods

    soptted_pods=$(oc get pod --all-namespaces | grep -Evi "running|Completed" |grep -v NAMESPACE)
    if [[ -n "$soptted_pods" ]]; then
        echo "There are some abnormal pods:"
        echo "${soptted_pods}"
    fi
    echo "Show all pods for reference/debug"
    run_command "oc get pods --all-namespaces"
}


function health_check() {

  EXPECTED_VERSION=$(oc get clusterversion/version -o json | jq -r '.status.history[0].version')
  export EXPECTED_VERSION

  run_command "oc get machineconfig"

  echo "Step #1: Make sure no degrated or updating mcp"
  wait_mcp_continous_success || return 1

  echo "Step #2: check all cluster operators get stable and ready"
  wait_clusteroperators_continous_success || return 1

  echo "Step #3: Make sure every machine is in 'Ready' status"
  check_node || return 1

  echo "Step #4: check all pods are in status running or complete"
  check_pod || return 1
}


set +e

echo "Health check for cluster 1:"
if [[ -f ${install_dir1}/auth/kubeconfig ]]; then
  export KUBECONFIG=${install_dir1}/auth/kubeconfig
  health_check
  health_ret=$?
  ret=$((ret+health_ret))
else
  echo "Error: no kubeconfig found for cluster 1"
  ret=$((ret+1))
fi


echo "Health check for cluster 2:"
if [[ -f ${install_dir2}/auth/kubeconfig ]]; then
  export KUBECONFIG=${install_dir2}/auth/kubeconfig
  health_check
  health_ret=$?
  ret=$((ret+health_ret))
else
  echo "Error: no kubeconfig found for cluster 2"
  ret=$((ret+1))
fi

exit $ret
