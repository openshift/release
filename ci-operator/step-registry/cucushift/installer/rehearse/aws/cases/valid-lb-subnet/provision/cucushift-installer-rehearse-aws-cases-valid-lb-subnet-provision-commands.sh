#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Validation for platform.aws.vpc
#
# platform:
#   aws:
#     region: us-east-1
#     vpc:
#       subnets:
#         - id: subnet-099756b44ea2c3a12
#           roles:
#             - type: ControlPlaneInternalLB
#             - type: ClusterNode
#         - id: subnet-0e9599a396c80bae9
#           roles:
#             - type: IngressControllerLB
#             - type: ControlPlaneExternalLB
#             - type: BootstrapNode

# https://github.com/gcs278/enhancements/blob/30f44ee0cd57dc4ba3b72e10c0b8f1614970d0e0/enhancements/installer/aws-lb-subnet-selection.md

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"; post_actions' EXIT TERM


export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
workdir=$(mktemp -d)
 
# only us-east-1 is satisify to 5 AZs requirement for this test, so LEASE_RESOURCE won't be used
REGION=us-east-1

global_ret=0

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
CLUSTER_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
INSTALL_DIR_BASE=${workdir}/installer_dirs
mkdir -p ${INSTALL_DIR_BASE}
INSTALLER_BINARY="openshift-install"
failed_cases_json=${ARTIFACT_DIR}/failed_cases.json
succeed_cases_json=${ARTIFACT_DIR}/succeed_cases.json
echo -n '[]' > "$failed_cases_json"
echo -n '[]' > "$succeed_cases_json"

echo "openshift-install version:"
$INSTALLER_BINARY version

function post_actions()
{
  set +o errexit

  echo "---------------"
  echo "Running post actions"
  for stack_name in `tac "${SHARED_DIR}/to_be_removed_cf_stack_list"`; do 

    # save events
    echo "Saving events for stack ${stack_name} ..."
    aws --region ${REGION} cloudformation describe-stack-events --stack-name ${stack_name} --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.json"

    # delete stacks
    echo "Deleting stack ${stack_name} ..."
    aws --region ${REGION} cloudformation delete-stack --stack-name "${stack_name}" &
    wait "$!"
    echo "Deleted stack ${stack_name}"

    aws --region ${REGION} cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
    wait "$!"
    echo "Waited for stack ${stack_name}"

  done

  if [[ -f "${SHARED_DIR}/security_groups_ids" ]]; then
    for sg_id in $(cat ${SHARED_DIR}/security_groups_ids); do
      echo "Deleting sg - ${sg_id}... "
      aws --region $REGION ec2 delete-security-group --group-id ${sg_id} 
    done
  fi

}

function create_stack()
{
  local region=$1
  local stack_name=$2
  local tpl=$3
  local output=$4
  local param=${5:-}
  local cmd

  echo ${stack_name} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  cmd="aws --region ${region} cloudformation create-stack "
  cmd="${cmd} --stack-name ${stack_name} --template-body file://${tpl} --tags ${TAGS} "
  if [[ "${param}" != "" ]]; then
    cmd="${cmd} --parameters file://${param} "
  fi
  eval "${cmd}"
  echo "Waiting"
  aws --region "${region}" cloudformation wait stack-create-complete --stack-name "${stack_name}"
  echo "Writing output"
  aws --region "${region}" cloudformation describe-stacks --stack-name "${stack_name}" > "${output}"
  echo "Done."
}

function create_install_config()
{
    local install_dir=$1
    local cluster_name=$2
    # External Internal
    local publish=$3

    mkdir -p $install_dir
    cat > ${install_dir}/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 3
controlPlane:
  architecture: amd64
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
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${REGION}
publish: ${publish}
pullSecret: >
  ${pull_secret}
sshKey: |
  ${ssh_pub_key}
EOF

}

function patch_edge_pool()
{
  local config=$1
  shift
  edge_zones=$(echo "$@" | yq-v4 -o yaml 'split(" ") | map(.)')
  export edge_zones
  cat > ${workdir}/edge-pool-patch << EOF
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: edge
  platform: {}
  replicas: 1
EOF
  yq-v4 eval -i '.compute[0].platform.aws.zones += env(edge_zones)' ${workdir}/edge-pool-patch
  yq-v4 eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' ${config} ${workdir}/edge-pool-patch
  unset edge_zones
}

function patch_legcy_subnets()
{
    local config=$1
    shift
    for subnet in "$@"; do
        export subnet
        yq-v4 eval -i '.platform.aws.subnets += [env(subnet)]' ${config}
        unset subnet
    done
}

function patch_new_subnets()
{
    local config=$1
    shift
    for subnet in "$@"; do
        export subnet
        yq-v4 eval -i '.platform.aws.vpc.subnets += [{"id": env(subnet)}]' ${config}
        unset subnet
    done
}

function patch_new_subnet_with_roles()
{
    local config=$1
    local subnet=$2
    shift 2
    roles=$(echo "$@" | yq-v4 -o yaml 'split(" ") | map({"type": .})')
    export subnet roles
    yq-v4 eval -i '.platform.aws.vpc.subnets += [{"id": env(subnet), "roles": env(roles)}]' ${config}
    unset subnet roles
}

function patch_az()
{
    local config=$1
    shift
    azs=$(echo "$@" | yq-v4 -o yaml 'split(" ") | map(.)')
    export azs
    yq-v4 eval -i '.compute[0].platform.aws.zones += env(azs)' ${config}
    yq-v4 eval -i '.controlPlane.platform.aws.zones += env(azs)' ${config}
    unset azs
}

function aws_add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

function create_manifests() {
    local install_dir=$1
    local ret=0

    yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform, "publish": .publish})' ${install_dir}/install-config.yaml > ${install_dir}/ic-summary.yaml
    yq-v4 e ${install_dir}/ic-summary.yaml

    echo "Creating manifests in ${install_dir} ..."
    set +e
    $INSTALLER_BINARY create manifests --dir $install_dir
    ret=$?
    echo $ret > ${install_dir}/ret_code
    set -e
}

function expect_regex()
{
  local install_dir=$1
  local desc=$2
  local regex=$3
  echo "Checking if \"${regex}\" in ${install_dir}/.openshift_install.log"
  
  local log ret ic
  log=$(tail -n 1 ${install_dir}/.openshift_install.log)
  ret=$(cat ${install_dir}/ret_code)
  ic=$(yq-v4 -o=json '.' ${install_dir}/ic-summary.yaml | jq -c)

  if grep -qE "${regex}" ${install_dir}/.openshift_install.log;
  then
    echo "PASS: ${desc}"
    cat <<< "$(jq  --arg desc "$desc" --arg log "$log" --arg regex "$regex" --arg ret "$ret" --argjson ic "$ic" '. += [{"desc":$desc, "log":$log, "regex":$regex, "ret":$ret, "ic":$ic}]' "$succeed_cases_json")" > "$succeed_cases_json"
  else
    echo "FAIL: ${desc}"    
    cat <<< "$(jq  --arg desc "$desc" --arg log "$log" --arg regex "$regex" --arg ret "$ret" --argjson ic "$ic" '. += [{"desc":$desc, "log":$log, "regex":$regex, "ret":$ret, "ic":$ic}]' "$failed_cases_json")" > "$failed_cases_json"
    global_ret=$((global_ret+1))
  fi
}

function print_title()
{
  local desc="$1"
  echo "-----------------------------------------------------------------------"
  echo "$desc"
  echo "-----------------------------------------------------------------------"
}

existing_cluster_names=()
function gen_cluster_name()
{
  local new_name
  local exist
  while true
  do
    new_name="${CLUSTER_NAME_PREFIX}-$(openssl rand -hex 1)"
    exist="no"
    for n in "${existing_cluster_names[@]}"
    do
      [[ "${n}" = "${new_name}" ]] && exist="yes"
    done

    if [[ "${exist}" == "no" ]]; then
      existing_cluster_names+=("${new_name}")
      echo ${new_name}
      break
    fi
  done
}


# ---------------------------------------------------------------------------------------------------
# Create VPC stacks
# ---------------------------------------------------------------------------------------------------

cat > ${workdir}/vpc.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice VPC with 1-6 AZs

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  AvailabilityZoneCount:
    ConstraintDescription: "The number of availability zones. (Min: 1, Max: 3)"
    MinValue: 1
    MaxValue: 6
    Default: 6
    Description: "How many AZs to create VPC subnets for. (Min: 1, Max: 3)"
    Type: Number
  SubnetBits:
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/19-27.
    MinValue: 5
    MaxValue: 13
    Default: 12
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /27, Max: 13 = /19)"
    Type: Number
  AllowedAvailabilityZoneList:
    ConstraintDescription: "Select AZs from this list, e.g. 'us-east-2c,us-east-2a'"
    Type: CommaDelimitedList
    Default: ""

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
  DoAz6: !Equals [6, !Ref AvailabilityZoneCount]
  DoAz5: !Or [!Equals [5, !Ref AvailabilityZoneCount], Condition: DoAz6]
  DoAz4: !Or [!Equals [4, !Ref AvailabilityZoneCount], Condition: DoAz5, Condition: DoAz6]
  DoAz3: !Or [!Equals [3, !Ref AvailabilityZoneCount], Condition: DoAz4, Condition: DoAz5, Condition: DoAz6]
  DoAz2: !Or [!Equals [2, !Ref AvailabilityZoneCount], Condition: DoAz3, Condition: DoAz4, Condition: DoAz5, Condition: DoAz6]
  AzRestriction: !Not [ !Equals [!Join ['', !Ref AllowedAvailabilityZoneList], ''] ]

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
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet1a:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
      Tags:
      - Key: kubernetes.io/cluster/unmanaged
        Value: "true"
  PublicSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [1, !Ref AllowedAvailabilityZoneList ],
              !Select [1, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [2, !Ref AllowedAvailabilityZoneList ],
              !Select [2, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet4:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz4
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [3, !Ref AllowedAvailabilityZoneList ],
              !Select [3, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet5:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz5
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [4, !Ref AllowedAvailabilityZoneList ],
              !Select [4, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet6:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz6
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [6, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [5, !Ref AllowedAvailabilityZoneList ],
              !Select [5, Fn::GetAZs: !Ref "AWS::Region"]
            ]
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
  PublicSubnet1aRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet1a
      RouteTableId: !Ref PublicRouteTable
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
  PublicSubnetRouteTableAssociation4:
    Condition: DoAz4
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet4
      RouteTableId: !Ref PublicRouteTable
  PublicSubnetRouteTableAssociation5:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz5
    Properties:
      SubnetId: !Ref PublicSubnet5
      RouteTableId: !Ref PublicRouteTable
  PublicSubnetRouteTableAssociation6:
    Condition: DoAz6
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet6
      RouteTableId: !Ref PublicRouteTable
  PrivateSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [7, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
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
  PrivateSubnet1a:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [8, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
      Tags:
      - Key: kubernetes.io/cluster/unmanaged
        Value: "true"
  PrivateRouteTable1a:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation1a:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnet1a
      RouteTableId: !Ref PrivateRouteTable1a
  NAT1a:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP1a
        - AllocationId
      SubnetId: !Ref PublicSubnet1a
  EIP1a:
    Type: "AWS::EC2::EIP"
    Properties:
      Domain: vpc
  Route1a:
    Type: "AWS::EC2::Route"
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable1a
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT1a
  PrivateSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [9, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [1, !Ref AllowedAvailabilityZoneList ],
              !Select [1, Fn::GetAZs: !Ref "AWS::Region"]
            ]
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
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [10, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [2, !Ref AllowedAvailabilityZoneList ],
              !Select [2, Fn::GetAZs: !Ref "AWS::Region"]
            ]
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
  PrivateSubnet4:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz4
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [11, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [3, !Ref AllowedAvailabilityZoneList ],
              !Select [3, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable4:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz4
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation4:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz4
    Properties:
      SubnetId: !Ref PrivateSubnet4
      RouteTableId: !Ref PrivateRouteTable4
  NAT4:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz4
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP4
        - AllocationId
      SubnetId: !Ref PublicSubnet4
  EIP4:
    Type: "AWS::EC2::EIP"
    Condition: DoAz4
    Properties:
      Domain: vpc
  Route4:
    Type: "AWS::EC2::Route"
    Condition: DoAz4
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable4
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT4
  PrivateSubnet5:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz5
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [12, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [4, !Ref AllowedAvailabilityZoneList ],
              !Select [4, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable5:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz5
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation5:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz5
    Properties:
      SubnetId: !Ref PrivateSubnet5
      RouteTableId: !Ref PrivateRouteTable5
  NAT5:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz5
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP5
        - AllocationId
      SubnetId: !Ref PublicSubnet5
  EIP5:
    Type: "AWS::EC2::EIP"
    Condition: DoAz5
    Properties:
      Domain: vpc
  Route5:
    Type: "AWS::EC2::Route"
    Condition: DoAz5
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable5
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT5
  PrivateSubnet6:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz6
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [13, !Cidr [!Ref VpcCidr, 16, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [5, !Ref AllowedAvailabilityZoneList ],
              !Select [5, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable6:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz6
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation6:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz6
    Properties:
      SubnetId: !Ref PrivateSubnet6
      RouteTableId: !Ref PrivateRouteTable6
  NAT6:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz6
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP6
        - AllocationId
      SubnetId: !Ref PublicSubnet6
  EIP6:
    Type: "AWS::EC2::EIP"
    Condition: DoAz6
    Properties:
      Domain: vpc
  Route6:
    Type: "AWS::EC2::Route"
    Condition: DoAz6
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable6
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT6
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
      - !If [DoAz4, !Ref PrivateRouteTable4, !Ref "AWS::NoValue"]
      - !If [DoAz5, !Ref PrivateRouteTable5, !Ref "AWS::NoValue"]
      - !If [DoAz6, !Ref PrivateRouteTable6, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VPC
Outputs:
  VpcId:
    Description: ID of the new VPC.
    Value: !Ref VPC
  PublicSubnetIds:
    Description: Subnet IDs of the public subnets.
    Value:
      !Join [",",
      [
        !Ref PublicSubnet,
        !If [DoAz2, !Ref PublicSubnet2, !Ref "AWS::NoValue"],
        !If [DoAz3, !Ref PublicSubnet3, !Ref "AWS::NoValue"],
        !If [DoAz4, !Ref PublicSubnet4, !Ref "AWS::NoValue"],
        !If [DoAz5, !Ref PublicSubnet5, !Ref "AWS::NoValue"],
        !If [DoAz6, !Ref PublicSubnet6, !Ref "AWS::NoValue"]
      ]
    ]
  PrivateSubnetIds:
    Description: Subnet IDs of the private subnets.
    Value:
      !Join [",",
      [
        !Ref PrivateSubnet,
        !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"],
        !If [DoAz3, !Ref PrivateSubnet3, !Ref "AWS::NoValue"],
        !If [DoAz4, !Ref PrivateSubnet4, !Ref "AWS::NoValue"],
        !If [DoAz5, !Ref PrivateSubnet5, !Ref "AWS::NoValue"],
        !If [DoAz6, !Ref PrivateSubnet6, !Ref "AWS::NoValue"]
      ]
    ]
  PublicSubnetIdsInTheSameAZ:
    Description: Subnet IDs of the public subnets in the same AZ.
    Value:
      !Join [",",
      [
        !Ref PublicSubnet,
        !Ref PublicSubnet1a
      ]
    ]
  PrivateSubnetIdsInTheSameAZ:
    Description: Subnet IDs of the private subnets in the same AZ.
    Value:
      !Join [",",
      [
        !Ref PrivateSubnet,
        !Ref PrivateSubnet1a
      ]
    ]
  PublicRouteTableId:
    Description: Public Route table ID
    Value: !Ref PublicRouteTable
  PrivateRouteTableIds:
    Description: Private Route table IDs
    Value:
      !Join [
        ",",
        [
          !Join ["=", [
            !Select [0, "Fn::GetAZs": !Ref "AWS::Region"],
            !Ref PrivateRouteTable
          ]],
          !If [DoAz2,
               !Join ["=", [!Select [1, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable2]],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz3,
               !Join ["=", [!Select [2, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable3]],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz4,
               !Join ["=", [!Select [3, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable4]],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz5,
               !Join ["=", [!Select [4, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable5]],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz6,
               !Join ["=", [!Select [5, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable6]],
               !Ref "AWS::NoValue"
          ]
        ]
      ]
EOF

cat > ${workdir}/subnet.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice Subnets (Public and Private)

Parameters:
  VpcId:
    Description: VPC ID which the subnets will be part.
    Type: String
    AllowedPattern: ^(?:(?:vpc)(?:-[a-zA-Z0-9]+)?\b|(?:[0-9]{1,3}\.){3}[0-9]{1,3})$
    ConstraintDescription: VPC ID must be with valid name, starting with vpc-.*.
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  SubnetBits:
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/19-27.
    MinValue: 5
    MaxValue: 13
    Default: 12
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /27, Max: 13 = /19)"
    Type: Number
  PrefixName:
    Description: Cluster Name or Prefix name to prepend the tag Name for each subnet.
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: PrefixName parameter must be specified.
  EdgeZoneName:
    Description: Zone Name to create the subnets (Example us-west-2-lax-1a).
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: EdgeZoneName parameter must be specified.
  PublicRouteTableId:
    Description: Public Route Table ID to associate the public subnet.
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: PublicRouteTableId parameter must be specified.
  PublicSubnetCidr:
    Description: CIDR block for Public Subnet
    Type: String
  PrivateRouteTableId:
    Description: Public Route Table ID to associate the Local Zone subnet
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: PublicRouteTableId parameter must be specified.
  PrivateSubnetCidr:
    Description: CIDR block for Public Subnet
    Type: String

Resources:
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VpcId
      CidrBlock: !Ref PublicSubnetCidr
      AvailabilityZone: !Ref EdgeZoneName
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref PrefixName, "public", !Ref EdgeZoneName]]
      - Key: kubernetes.io/cluster/unmanaged
        Value: "true"

  PublicSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTableId

  PrivateSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VpcId
      CidrBlock: !Ref PrivateSubnetCidr
      AvailabilityZone: !Ref EdgeZoneName
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref PrefixName, "private", !Ref EdgeZoneName]]
      - Key: kubernetes.io/cluster/unmanaged
        Value: "true"

  PrivateSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTableId

Outputs:
  PublicSubnetId:
    Description: Subnet ID of the public subnets.
    Value:
      !Join ["", [!Ref PublicSubnet]]

  PrivateSubnetId:
    Description: Subnet ID of the private subnets.
    Value:
      !Join ["", [!Ref PrivateSubnet]]
EOF

cat > ${workdir}/carrier_gateway.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Creating Wavelength Zone Gateway (Carrier Gateway).

Parameters:
  VpcId:
    Description: VPC ID to associate the Carrier Gateway.
    Type: String
    AllowedPattern: ^(?:(?:vpc)(?:-[a-zA-Z0-9]+)?\b|(?:[0-9]{1,3}\.){3}[0-9]{1,3})$
    ConstraintDescription: VPC ID must be with valid name, starting with vpc-.*.
  PrefixName:
    Description: Cluster Name or Prefix name to prepend the tag Name for each subnet.
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: PrefixName parameter must be specified.

Resources:
  CarrierGateway:
    Type: "AWS::EC2::CarrierGateway"
    Properties:
      VpcId: !Ref VpcId
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref PrefixName, "cagw"]]

  PublicRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VpcId
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref PrefixName, "public-carrier"]]

  PublicRoute:
    Type: "AWS::EC2::Route"
    DependsOn: CarrierGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      CarrierGatewayId: !Ref CarrierGateway

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
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VpcId

Outputs:
  PublicRouteTableId:
    Description: Public Route table ID
    Value: !Ref PublicRouteTable
EOF

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

VPC_1_STACK_NAME=${CLUSTER_NAME_PREFIX}-vpc-1
VPC_2_STACK_NAME=${CLUSTER_NAME_PREFIX}-vpc-2
VPC_1_STACK_OUTPUT=${ARTIFACT_DIR}/vpc_1_output.json
VPC_2_STACK_OUTPUT=${ARTIFACT_DIR}/vpc_2_output.json

echo "Creating ${VPC_1_STACK_NAME}"
create_stack $REGION ${VPC_1_STACK_NAME} ${workdir}/vpc.yaml ${VPC_1_STACK_OUTPUT}

echo "Creating ${VPC_2_STACK_NAME}"
create_stack $REGION ${VPC_2_STACK_NAME} ${workdir}/vpc.yaml ${VPC_2_STACK_OUTPUT}

vpc1_id=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue' "${VPC_1_STACK_OUTPUT}")

vpc1_pub1=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[0]' "${VPC_1_STACK_OUTPUT}")
vpc1_priv1=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[0]' "${VPC_1_STACK_OUTPUT}")

vpc1_pub1a=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIdsInTheSameAZ") | .OutputValue | split(",")[1]' "${VPC_1_STACK_OUTPUT}")
vpc1_priv1a=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIdsInTheSameAZ") | .OutputValue | split(",")[1]' "${VPC_1_STACK_OUTPUT}")

vpc1_pub2=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[1]' "${VPC_1_STACK_OUTPUT}")
vpc1_priv2=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[1]' "${VPC_1_STACK_OUTPUT}")

vpc2_pub1=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[0]' "${VPC_2_STACK_OUTPUT}")
vpc2_priv1=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[0]' "${VPC_2_STACK_OUTPUT}")


# platform.aws.subnets is deprecated
#
# warning msg:
#  WARNING platform.aws.subnets is deprecated. Converted to platform.aws.vpc.subnets

desc="platform.aws.subnets is deprecated"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
for subnet in $(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]' ${VPC_1_STACK_OUTPUT});
do
    patch_legcy_subnets $config ${subnet}
done
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=warning.*platform.aws.subnets is deprecated. Converted to platform.aws.vpc.subnets.*"

# Subnet ids must not duplicate
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: [platform.aws.vpc.subnets[2].id: Duplicate value: "subnet-0a8f1af0450eaa90c", platform.aws.vpc.subnets[3].id: Duplicate value: "subnet-08f39ad76791e5c4c"]
desc="Subnet ids must not duplicate"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnets $config ${vpc1_pub2}
patch_new_subnets $config ${vpc1_priv2}
patch_new_subnets $config ${vpc1_pub2}
patch_new_subnets $config ${vpc1_priv2}
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Duplicate value.*subnet.*"

# The subnet role must be supported
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets[0].roles[2].type: Unsupported value: "NotSupportRole": supported values: "BootstrapNode", "ClusterNode", "ControlPlaneExternalLB", "ControlPlaneInternalLB", "EdgeNode", "IngressControllerLB"
desc="The subnet role must be supported"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode NotSupportRole
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Unsupported value.*NotSupportRole.*supported values.*"

# Roles must not be duplicated
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets[0].roles[2].type: Duplicate value: "ControlPlaneExternalLB"
desc="Roles must not be duplicated"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Duplicate value.*ControlPlaneExternalLB.*"



# Each role must be assigned to at least 1 subnet
#

desc="Role must be assigned to at least 1 subnet: IngressControllerLB/ControlPlaneExternalLB/ClusterNode/BootstrapNode/ControlPlaneInternalLB if cluster is public"
print_title "${desc}"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Invalid value: []aws.Subnet{aws.Subnet{ID:"subnet-04ed90d39b605e4f2", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"BootstrapNode"}}}, aws.Subnet{ID:"subnet-07a9b2e507f3f769d", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"ControlPlaneInternalLB"}}}}: roles [ClusterNode ControlPlaneExternalLB IngressControllerLB] must be assigned to at least 1 subnet
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*roles \\[ClusterNode ControlPlaneExternalLB IngressControllerLB\\] must be assigned to at least 1 subnet.*"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Invalid value: []aws.Subnet{aws.Subnet{ID:"subnet-04ed90d39b605e4f2", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"IngressControllerLB"}, aws.SubnetRole{Type:"ControlPlaneExternalLB"}}}, aws.Subnet{ID:"subnet-07a9b2e507f3f769d", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"ClusterNode"}}}}: roles [BootstrapNode ControlPlaneInternalLB] must be assigned to at least 1 subnet
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*roles \\[BootstrapNode ControlPlaneInternalLB\\] must be assigned to at least 1 subnet.*"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Invalid value: []aws.Subnet{aws.Subnet{ID:"subnet-04ed90d39b605e4f2", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"BootstrapNode"}}}, aws.Subnet{ID:"subnet-07a9b2e507f3f769d", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"ControlPlaneInternalLB"}}}}: roles [ClusterNode IngressControllerLB] must be assigned to at least 1 subnet
desc="Role must be assigned to at least 1 subnet: IngressControllerLB/ClusterNode/BootstrapNode/ControlPlaneInternalLB if cluster is private"
print_title "${desc}"

cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
patch_new_subnet_with_roles $config ${vpc1_pub1} BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*roles \\[ClusterNode IngressControllerLB\\] must be assigned to at least 1 subnet.*"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Invalid value: []aws.Subnet{aws.Subnet{ID:"subnet-04ed90d39b605e4f2", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"IngressControllerLB"}}}, aws.Subnet{ID:"subnet-07a9b2e507f3f769d", Roles:[]aws.SubnetRole{aws.SubnetRole{Type:"ClusterNode"}}}}: roles [BootstrapNode ControlPlaneInternalLB] must be assigned to at least 1 subnet
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*roles \\[BootstrapNode ControlPlaneInternalLB\\] must be assigned to at least 1 subnet.*"


# All or Nothing Subnet Roles Selection
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Forbidden: either all subnets must be assigned roles or none of the subnets should have roles assigned
desc="All or Nothing Subnet Roles Selection"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnets $config ${vpc1_pub2}
patch_new_subnets $config ${vpc1_priv2}
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*either all subnets must be assigned roles or none of the subnets should have roles assigned.*"


# The Old and New Subnets Fields Cannot be Specified Together Validation
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: failed to upconvert install config: platform.aws.subnets: Forbidden: cannot specify platform.aws.subnets and platform.aws.vpc.subnets together
desc="The Old and New Subnets Fields Cannot be Specified Together Validation"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_legcy_subnets $config ${vpc1_pub1}
patch_legcy_subnets $config ${vpc1_priv1}
patch_new_subnets $config ${vpc1_pub1}
patch_new_subnets $config ${vpc1_priv1}
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: cannot specify platform.aws.subnets and platform.aws.vpc.subnets together.*"

# Maximum of 10 IngressController Subnets Validation
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Forbidden: must not include more than 10 subnets with the IngressControllerLB role
desc="Maximum of 10 IngressController Subnets Validation"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB

for subnet in $(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]' ${VPC_1_STACK_OUTPUT});
do
    if [[ "${subnet}" == "${vpc1_pub1}" ]] || [[ "${subnet}" == "${vpc1_priv1}" ]]; then
        continue
    fi
    patch_new_subnet_with_roles $config  ${subnet} IngressControllerLB
done
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: must not include more than 10 subnets with the IngressControllerLB role.*"

# All Subnets Belong to the Same VPC Validation
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: unable to load edge subnets: error retrieving Edge Subnets: all subnets must belong to the same VPC: subnet-0347908772d9548e7 is from vpc-09a7e910061ab0092, but subnet-06f2129c91e7a3097 is from vpc-0f59fc74700f526fa: error retrieving Edge Subnets: all subnets must belong to the same VPC: subnet-0347908772d9548e7 is from vpc-09a7e910061ab0092, but subnet-06f2129c91e7a3097 is from vpc-0f59fc74700f526fa
desc="All Subnets Belong to the Same VPC Validation"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnets $config ${vpc1_priv1}
patch_new_subnets $config ${vpc1_pub1}
patch_new_subnets $config ${vpc2_priv1}
patch_new_subnets $config ${vpc2_pub1}
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*all subnets must belong to the same VPC.*"

# Consistent Cluster Scope with IngressControllerLB Subnets Validation
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: platform.aws.vpc.subnets[1]: Invalid value: "subnet-0347908772d9548e7": subnet subnet-0347908772d9548e7 has role IngressControllerLB and is private, which is not allowed when publish is set to External
desc="Consistent Cluster Scope with IngressControllerLB Subnets Validation: IngressControllerLB can not be assigned to private subnet if cluster is public."
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB IngressControllerLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*subnet.*has role IngressControllerLB and is private, which is not allowed when publish is set to External.*"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Forbidden: must not include subnets with the ControlPlaneExternalLB role in a private cluster
desc="Consistent Cluster Scope with IngressControllerLB Subnets Validation: IngressControllerLB can not be assigned to public subnet if cluster is private."
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB BootstrapNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*subnet.*has role IngressControllerLB and is public, which is not allowed when publish is set to Internal.*"

# Consistent Cluster Scope with ControlPlaneLB Subnets Validation
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: [platform.aws.vpc.subnets[0]: Invalid value: "subnet-0affca345511a071c": subnet subnet-0affca345511a071c has role ControlPlaneInternalLB, but is public, expected to be private, platform.aws.vpc.subnets[1]: Invalid value: "subnet-0347908772d9548e7": subnet subnet-0347908772d9548e7 has role ControlPlaneExternalLB, but is private, expected to be public]
desc="Consistent Cluster Scope with ControlPlaneLB Subnets Validation: ControlPlaneExternalLB must be assigned to public subnet, ControlPlaneInternalLB must be assigned to private subnet"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneInternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneExternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*subnet.*has role ControlPlaneExternalLB, but is private, expected to be public.*"
expect_regex $install_dir "${desc}" "level=error.*subnet.*has role ControlPlaneInternalLB, but is public, expected to be private.*"


# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets[0].roles: Forbidden: must not have both ControlPlaneExternalLB and ControlPlaneInternalLB role
desc="Consistent Cluster Scope with ControlPlaneLB Subnets Validation: ControlPlaneExternalLB and ControlPlaneInternalLB can not be assigned to the same subnet"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneInternalLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: must not have both ControlPlaneExternalLB and ControlPlaneInternalLB role.*"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets: Forbidden: must not include subnets with the ControlPlaneExternalLB role in a private cluster
desc="Consistent Cluster Scope with ControlPlaneLB Subnets Validation: ControlPlaneExternalLB can not be assigned if cluster is private"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
patch_new_subnet_with_roles $config ${vpc1_pub1} ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode  BootstrapNode ControlPlaneInternalLB IngressControllerLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: must not include subnets with the ControlPlaneExternalLB role in a private cluster.*"

# Reject BYO VPC Installations that Contain Untagged Subnets
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: platform.aws.vpc.subnets: Forbidden: additional subnets [subnet-00ce44896c9c43e08 subnet-0117ab8924372b16c subnet-0239b663fb422f675 subnet-0310498ed4d5737a3 subnet-03b9b7945c451129a subnet-04ba939f353cf0ee1 subnet-04f6003ecf2154b3e subnet-06fc8cd15dbb60b62 subnet-0980816fec908bd10 subnet-0b5dcacc78ba6a6e8 subnet-0bc6e39606c6e5c1f subnet-0f5acb4b2b3016a7d] without tag prefix kubernetes.io/cluster/ are found in vpc vpc-09a7e910061ab0092 of provided subnets. Please add a tag kubernetes.io/cluster/unmanaged to those subnets to exclude them from cluster installation or explicitly assign roles to provided subnets
desc="Reject BYO VPC Installations that Contain Untagged Subnets"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnets $config ${vpc1_pub1}
patch_new_subnets $config ${vpc1_priv1}
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: additional subnets.*without tag prefix kubernetes.io/cluster/ are found in vpc vpc-.* of provided subnets. Please add a tag kubernetes.io/cluster/unmanaged to those subnets to exclude them from cluster installation or explicitly assign roles in the install-config to provided subnets.*"

# error msg:
# level=error msg="failed to fetch Master Machines: failed to load asset \"Install Config\": failed to create install config: platform.aws.vpc.subnets: Forbidden: additional subnets [subnet-009578796497415b2 subnet-013797a79afb77442 subnet-018ab3d120fe468c0 subnet-060dfb034e0a04c3d subnet-0721289c24c0f8f21 subnet-096facc9c8a1b0b07 subnet-0ab35ec555d9ed825 subnet-0aec18801727d06de subnet-0d6bd7b7a83a5bf81 subnet-0da3c7a64a7c88e46 subnet-0e67021e39d4ce8ae] without tag prefix kubernetes.io/cluster/ are found in vpc vpc-0d259b77dfec5f6d6 of provided subnets. Please add a tag kubernetes.io/cluster/unmanaged to those subnets to exclude them from cluster installation or explicitly assign roles in the install-config to provided subnets"
desc="Reject BYO VPC Installations that Contain Untagged Subnets - public only cluster"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
for s in $(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue' "${VPC_1_STACK_OUTPUT}" | sed 's/,/ /g');
do
  patch_new_subnets $config ${s}
done
export OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY=true
create_manifests $install_dir
unset OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY
expect_regex $install_dir "${desc}" "level=error.*Forbidden: additional subnets.*without tag prefix kubernetes.io/cluster/ are found in vpc vpc-.* of provided subnets. Please add a tag kubernetes.io/cluster/unmanaged to those subnets to exclude them from cluster installation or explicitly assign roles in the install-config to provided subnets.*"

desc="Reject BYO VPC Installations that Contain Untagged Subnets - private cluster"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
for s in $(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue' "${VPC_1_STACK_OUTPUT}" | sed 's/,/ /g');
do
  patch_new_subnets $config ${s}
done
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: additional subnets.*without tag prefix kubernetes.io/cluster/ are found in vpc vpc-.* of provided subnets. Please add a tag kubernetes.io/cluster/unmanaged to those subnets to exclude them from cluster installation or explicitly assign roles in the install-config to provided subnets.*"


# Reject IngressControllers or ControlPlaneLB AZs that do not match ClusterNode AZs
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: [platform.aws.vpc.subnets: Forbidden: zones [us-east-1b] are not enabled for ControlPlaneInternalLB load balancers, nodes in those zones are unreachable, platform.aws.vpc.subnets: Forbidden: zones [us-east-1a] are enabled for ControlPlaneInternalLB load balancers, but are not used by any nodes, platform.aws.vpc.subnets: Forbidden: zones [us-east-1b] are not enabled for IngressControllerLB load balancers, nodes in those zones are unreachable, platform.aws.vpc.subnets: Forbidden: zones [us-east-1a] are enabled for IngressControllerLB load balancers, but are not used by any nodes, platform.aws.vpc.subnets: Forbidden: zones [us-east-1b] are not enabled for ControlPlaneExternalLB load balancers, nodes in those zones are unreachable, platform.aws.vpc.subnets: Forbidden: zones [us-east-1a] are enabled for ControlPlaneExternalLB load balancers, but are not used by any nodes]
desc="Reject IngressControllers or ControlPlaneLB AZs that do not match ClusterNode AZs"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${vpc1_pub2} BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv2} ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: zones.*are not enabled for ControlPlaneInternalLB load balancers, nodes in those zones are unreachable.*"
expect_regex $install_dir "${desc}" "level=error.*Forbidden: zones.*are enabled for ControlPlaneInternalLB load balancers, but are not used by any nodes.*"
expect_regex $install_dir "${desc}" "level=error.*Forbidden: zones.*are not enabled for IngressControllerLB load balancers, nodes in those zones are unreachable.*"
expect_regex $install_dir "${desc}" "level=error.*Forbidden: zones.*are enabled for IngressControllerLB load balancers, but are not used by any nodes.*"
expect_regex $install_dir "${desc}" "level=error.*Forbidden: zones.*are not enabled for ControlPlaneExternalLB load balancers, nodes in those zones are unreachable.*"
expect_regex $install_dir "${desc}" "level=error.*Forbidden: zones.*are enabled for ControlPlaneExternalLB load balancers, but are not used by any nodes.*"

# The zones of provided subnets must match *.platform.aws.zones
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: [controlPlane.platform.aws.zones: Invalid value: []string{"us-east-1b"}: No subnets provided for zones [us-east-1b], compute[0].platform.aws.zones: Invalid value: []string{"us-east-1b"}: No subnets provided for zones [us-east-1b]]
desc="The zones of provided subnets must match *.platform.aws.zones"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
another_az=$(aws --region $REGION ec2 describe-subnets --subnet-id $vpc1_pub2 | jq -r '.Subnets[].AvailabilityZone')
patch_az $config $another_az
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*No subnets provided for zones.*"


# Edge Subnet Restrictions
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: invalid "install-config.yaml" file: platform.aws.vpc.subnets[0].roles: Forbidden: must not combine EdgeNode role with any other roles
desc="Edge Subnet Restrictions: must not combine EdgeNode role with any other roles"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB EdgeNode BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Forbidden: must not combine EdgeNode role with any other roles.*"

# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: platform.aws.vpc.subnets[2]: Invalid value: "subnet-0a8f1af0450eaa90c": subnet subnet-0a8f1af0450eaa90c has role EdgeNode, but is not in a Local or WaveLength Zone
desc="Edge Subnet Restrictions: EdgeNode can only be assigned to edge subnet"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${vpc1_pub2} EdgeNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*subnet.*has role EdgeNode, but is not in a Local or WaveLength Zone.*"


# ClusterNode can be applied to Private subnet only
#
# error msg:
desc="ClusterNode can be applied to Private subnet only"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB ClusterNode BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*subnet.*has role ClusterNode, but is public, expected to be private.*"


# Reject Duplicate AZs
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: [platform.aws.vpc.subnets[1]: Invalid value: "subnet-0347908772d9548e7": private subnet subnet-0310498ed4d5737a3 is also in zone us-east-1a, platform.aws.vpc.subnets[0]: Invalid value: "subnet-0affca345511a071c": public subnet subnet-0239b663fb422f675 is also in zone us-east-1a]
desc="Reject Duplicate AZs"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${vpc1_pub1a} ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_priv1a} ClusterNode ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*have role.*and are both in zone.*"

# installer now allows the subnets in the same AZs in the configuration *only* if roles are specified
# installer will still reject subnets in the same AZ if no role specified (classic restriction).
# see https://github.com/openshift/installer/pull/9663
desc="Reject Duplicate AZs if no roles specified"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnets $config ${vpc1_pub1}
patch_new_subnets $config ${vpc1_priv1}
patch_new_subnets $config ${vpc1_pub1a}
patch_new_subnets $config ${vpc1_priv1a}
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*private subnet subnet-.* is also in zone.*"
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*public subnet subnet-.* is also in zone .*"



# Multiple Load Balancer Subnets in the Same AZ Validation
#   The installer must reject multiple IngressControllerLB subnets in the same AZ as this will be rejected by the AWS CCM.
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: [platform.aws.vpc.subnets[1]: Invalid value: "subnet-0347908772d9548e7": private subnet subnet-0310498ed4d5737a3 is also in zone us-east-1a, platform.aws.vpc.subnets[0]: Invalid value: "subnet-0affca345511a071c": public subnet subnet-0239b663fb422f675 is also in zone us-east-1a, platform.aws.vpc.subnets[2]: Invalid value: "subnet-0239b663fb422f675": subnets subnet-0affca345511a071c and subnet-0239b663fb422f675 have role IngressControllerLB and are both in zone us-east-1a]
desc="Multiple Load Balancer Subnets in the Same AZ Validation"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${vpc1_pub1a} IngressControllerLB
patch_new_subnet_with_roles $config ${vpc1_priv1a} ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*subnets.*have role IngressControllerLB and are both in zone.*"

# ClusterNodes can be only applied to private subnet
desc="ClusterNodes can be only applied to private subnet"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} ControlPlaneExternalLB IngressControllerLB BootstrapNode ClusterNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*subnet.*has role ClusterNode, but is public, expected to be private.*"



# Valid configurations:
# 
desc="Valid: BootstrapNode can be applied to private subnet in private cluster"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB ClusterNode BootstrapNode IngressControllerLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: BootstrapNode can be applied to public subnet"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: Dedicated IngressControllerLB and ControlPlaneLB subnets which enable cluster admins to isolate"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1}  ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${vpc1_pub1a} IngressControllerLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1a} ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: Dedicated IngressControllerLB and ControlPlaneLB subnets, but ControlPlaneInternalLB is shared with ClusterNode"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1}  ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_pub1a} IngressControllerLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1a} ClusterNode ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: ClusterNodes on public subnets so that they are externally accessible"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} ControlPlaneExternalLB IngressControllerLB BootstrapNode ClusterNode
patch_new_subnet_with_roles $config ${vpc1_pub1a} ControlPlaneInternalLB
export OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY=true
create_manifests $install_dir
unset OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: Private cluster"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name Internal
patch_new_subnet_with_roles $config ${vpc1_priv1} ControlPlaneInternalLB IngressControllerLB BootstrapNode ClusterNode
patch_new_subnet_with_roles $config ${vpc1_priv2} ControlPlaneInternalLB IngressControllerLB ClusterNode
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"


desc="Valid: 2 private subnets in AZ1, 1 public subnet in AZ1"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1}  ControlPlaneExternalLB
patch_new_subnet_with_roles $config ${vpc1_pub1a} IngressControllerLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1a} ClusterNode ControlPlaneInternalLB
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"


# -------------------------------------------------
# Edge nodes
# -------------------------------------------------

# --------------------------------
# Create subnet in Local Zone
# --------------------------------
lz_params=${workdir}/lz_params.json
lz_stack_name=${CLUSTER_NAME_PREFIX}-lz
lz_output=${ARTIFACT_DIR}/lz_output.json
public_route_table_id=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicRouteTableId") | .OutputValue' "${VPC_1_STACK_OUTPUT}")
private_route_table_id=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateRouteTableIds") | .OutputValue' "${VPC_1_STACK_OUTPUT}" | sed 's/,/\n/g' | grep "us-east-1a" | cut -d '=' -f 2)
az_name=$(aws --region ${REGION} ec2 describe-subnets --subnet-id ${vpc1_pub1} | jq -r '.Subnets[0].AvailabilityZone')
lz_zone_name=$(aws --region ${REGION} ec2 describe-availability-zones --filters Name=zone-type,Values=local-zone Name=parent-zone-name,Values=$az_name | jq -r '.AvailabilityZones[0].ZoneName')
aws_add_param_to_json "VpcId" ${vpc1_id} "$lz_params"
aws_add_param_to_json "PrefixName" ${CLUSTER_NAME_PREFIX} "$lz_params"
aws_add_param_to_json "EdgeZoneName" ${lz_zone_name} "$lz_params"
aws_add_param_to_json "PublicRouteTableId" ${public_route_table_id} "$lz_params"
aws_add_param_to_json "PrivateRouteTableId" ${private_route_table_id} "$lz_params"
aws_add_param_to_json "PublicSubnetCidr" "10.0.224.0/26" "$lz_params"
aws_add_param_to_json "PrivateSubnetCidr" "10.0.225.0/26" "$lz_params"



echo "Creating ${lz_stack_name}"
create_stack $REGION ${lz_stack_name} ${workdir}/subnet.yaml ${lz_output} ${lz_params}

lz_public=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetId") | .OutputValue' ${lz_output})
lz_private=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetId") | .OutputValue' ${lz_output})

# --------------------------------
# Create subnet in Wavelength Zone
# --------------------------------

# gateway
wl_gateway_params=${workdir}/wl_gateway_params.json
wl_gateway_stack_name=${CLUSTER_NAME_PREFIX}-wl-gateway
wl_gateway_output=${ARTIFACT_DIR}/wl_gateway_output.json
aws_add_param_to_json "VpcId" ${vpc1_id} "$wl_gateway_params"
aws_add_param_to_json "PrefixName" ${CLUSTER_NAME_PREFIX} "$wl_gateway_params"
echo "Creating ${wl_gateway_stack_name}"
create_stack $REGION ${wl_gateway_stack_name} ${workdir}/carrier_gateway.yaml ${wl_gateway_output} ${wl_gateway_params}
public_route_table_id=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicRouteTableId") | .OutputValue' "${wl_gateway_output}")

# Wavelength Zone subnet
wl_params=${workdir}/wl_params.json
wl_stack_name=${CLUSTER_NAME_PREFIX}-wl
wl_output=${ARTIFACT_DIR}/wl_output.json
private_route_table_id=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateRouteTableIds") | .OutputValue' "${VPC_1_STACK_OUTPUT}" | sed 's/,/\n/g' | grep "us-east-1a" | cut -d '=' -f 2)
az_name=$(aws --region ${REGION} ec2 describe-subnets --subnet-id ${vpc1_pub1} | jq -r '.Subnets[0].AvailabilityZone')
wl_zone_name=$(aws --region ${REGION} ec2 describe-availability-zones --filters Name=zone-type,Values=wavelength-zone Name=parent-zone-name,Values=$az_name | jq -r '.AvailabilityZones[0].ZoneName')
aws_add_param_to_json "VpcId" ${vpc1_id} "$wl_params"
aws_add_param_to_json "PrefixName" ${CLUSTER_NAME_PREFIX} "$wl_params"
aws_add_param_to_json "EdgeZoneName" ${wl_zone_name} "$wl_params"
aws_add_param_to_json "PublicRouteTableId" ${public_route_table_id} "$wl_params"
aws_add_param_to_json "PrivateRouteTableId" ${private_route_table_id} "$wl_params"
aws_add_param_to_json "PublicSubnetCidr" "10.0.226.0/26" "$wl_params"
aws_add_param_to_json "PrivateSubnetCidr" "10.0.227.0/26" "$wl_params"

echo "Creating ${wl_stack_name}"
create_stack $REGION ${wl_stack_name} ${workdir}/subnet.yaml ${wl_output} ${wl_params}

wl_public=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetId") | .OutputValue' ${wl_output})
# wl_private=$(jq -c -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetId") | .OutputValue' ${wl_output})


# ClusterNode can not be applied to Local Zone subnet
#
# error msg:
# ERROR failed to fetch Master Machines: failed to load asset "Install Config": failed to create install config: platform.aws.vpc.subnets[2]: Invalid value: "subnet-0115c633b11c079fb": subnet subnet-0115c633b11c079fb must only be assigned role EdgeNode since it is in a Local or WaveLength Zone
desc="ClusterNode can not be applied to Local Zone subnet (public)"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${lz_public} ClusterNode
patch_edge_pool $config $lz_zone_name
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*subnet.*must only be assigned role EdgeNode since it is in a Local or WaveLength Zone.*"

desc="ClusterNode can not be applied to Local Zone subnet (private)"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${lz_private} ClusterNode
patch_edge_pool $config $lz_zone_name
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*subnet.*must only be assigned role EdgeNode since it is in a Local or WaveLength Zone.*"


desc="ClusterNode can not be applied to Wavelength Zone subnet"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${wl_public} ClusterNode
patch_edge_pool $config $wl_zone_name
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=error.*Invalid value.*subnet.*must only be assigned role EdgeNode since it is in a Local or WaveLength Zone.*"

desc="Valid: Cluster installation with Local Zone"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${lz_public} EdgeNode
patch_edge_pool $config $lz_zone_name
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: Cluster installation with Wavelength Zone"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_new_subnet_with_roles $config ${wl_public} EdgeNode
patch_edge_pool $config $wl_zone_name
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"


# --------------------------------
# additionalSecurityGroupIDs
# --------------------------------

# installconfig.compute.platform.aws.additionalSecurityGroupIDs
# installconfig.controlPlane.platform.aws.additionalSecurityGroupIDs
# installconfig.platform.aws.defaultMachinePlatform.additionalSecurityGroupIDs
function patch_security_group()
{
    local config=$1
    local sg=$2
    local item=$3

    case "${item}" in
      compute)
        export sg
        yq-v4 eval -i '.compute[0].platform.aws.additionalSecurityGroupIDs += [env(sg)]' ${config}
        unset sg
        ;;
      controlPlane)
        export sg
        yq-v4 eval -i '.controlPlane.platform.aws.additionalSecurityGroupIDs += [env(sg)]' ${config}
        unset sg
        ;;
      defaultMachinePlatform)
        export sg
        yq-v4 eval -i '.platform.aws.defaultMachinePlatform.additionalSecurityGroupIDs += [env(sg)]' ${config}
        unset sg
        ;;
      *)
        echo "ERROR: usage: patch_security_group [install-config] [sg-id] [compute|controlPlane|defaultMachinePlatform]"
        return 1
        ;;
    esac
}

sg_name=${CLUSTER_NAME_PREFIX}-sg
tag_json=$(mktemp)
cat << EOF > $tag_json
[
  {
    "ResourceType": "security-group",
    "Tags": [
      {
        "Key": "Name",
        "Value": "${sg_name}"
      }
    ]
  }
]
EOF

sg_id=$(aws ec2 create-security-group --region $REGION --group-name ${sg_name} --vpc-id $vpc1_id \
    --tag-specifications file://${tag_json} \
    --description "Prow CI Test: SG for aws-cases-valid-lb-subnet" | jq -r '.GroupId')
echo $sg_id > ${SHARED_DIR}/security_groups_ids


desc="Valid: LB Subnet roles with SG group in compute node"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_security_group $config ${sg_id} compute
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"

desc="Valid: LB Subnet roles with SG group in controlPlane node"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_security_group $config ${sg_id} controlPlane
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"


desc="Valid: LB Subnet roles with SG group in defaultMachinePlatform"
print_title "${desc}"
cluster_name=$(gen_cluster_name)
install_dir=${INSTALL_DIR_BASE}/${cluster_name}
config=${install_dir}/install-config.yaml
create_install_config $install_dir $cluster_name External
patch_new_subnet_with_roles $config ${vpc1_pub1} IngressControllerLB ControlPlaneExternalLB BootstrapNode
patch_new_subnet_with_roles $config ${vpc1_priv1} ClusterNode ControlPlaneInternalLB
patch_security_group $config ${sg_id} defaultMachinePlatform
create_manifests $install_dir
expect_regex $install_dir "${desc}" "level=info.*Manifests created in.*"


if [[ "$global_ret" != "0" ]]; then
  echo "FAILED CASES:"
  jq . $failed_cases_json
fi
echo "FINAL RESULT: $global_ret"

exit $global_ret
