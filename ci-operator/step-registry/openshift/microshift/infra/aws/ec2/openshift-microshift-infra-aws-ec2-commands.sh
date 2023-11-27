#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail
export PS4='+ $(date "+%T.%N") \011'

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save stacks events
trap 'save_stack_events_to_shared' EXIT TERM INT

# This map should be extended everytime AMIs from different regions/architectures/os versions
# are added.
declare -A ami_map=(
  [us-west-2,x86_64,rhel-9.2]=ami-0d5b3039c1132e1b2
  [us-west-2,x86_64,rhel-9.3]=ami-04b4d3355a2e2a403
  [us-west-2,arm64,rhel-9.2]=ami-0addfb94c944af1cc
  [us-west-2,arm64,rhel-9.3]=ami-0086e25ab5453b65e
)

# All graviton instances have a lower case g in the family part. Using
# this we avoid adding the full map here.
ARCH="x86_64"
if [[ "${EC2_INSTANCE_TYPE%.*}" =~ .*"g".* ]]; then
  ARCH="arm64"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${EC2_REGION:-$LEASED_RESOURCE}"
JOB_NAME="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${JOB_NAME}"
cf_tpl_file="${SHARED_DIR}/${JOB_NAME}-cf-tpl.yaml"

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"
if [ -f "${MICROSHIFT_CLUSTERBOT_SETTINGS}" ]; then
  : Overriding step defaults by sourcing clusterbot settings
  # shellcheck disable=SC1090
  source "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
fi

if [[ "${EC2_AMI}" == "" ]]; then
  EC2_AMI="${ami_map[$REGION,$ARCH,$MICROSHIFT_OS]}"
fi

ec2Type="VirtualMachine"
if [[ "$EC2_INSTANCE_TYPE" =~ c[0-9]+[gn].metal ]]; then
  ec2Type="MetalMachine"
fi

ami_id=${EC2_AMI}
instance_type=${EC2_INSTANCE_TYPE}
host_device_name="/dev/xvdc"

if [[ "$EC2_INSTANCE_TYPE" =~ a1.* ]] || [[ "$EC2_INSTANCE_TYPE" =~ c[0-9]+[gn].* ]]; then
  host_device_name="/dev/nvme1n1"
fi

function save_stack_events_to_shared()
{
  set +o errexit
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json > "${SHARED_DIR}/stack-events-${stack_name}.json"
  set -o errexit
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
     PrimaryVolumeSize: "300"
     SecondaryVolumeSize: "0"
     Throughput: 500
   VirtualMachine:
     PrimaryVolumeSize: "200"
     SecondaryVolumeSize: "10"
     Throughput: 125
Parameters:
  EC2Type:
    Default: 'VirtualMachine'
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
  HostDeviceName:
    Type: String
    Description: Disk device name to create pvs and vgs

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Host Information"
      Parameters:
      - HostInstanceType
    - Label:
        default: "Network Configuration"
      Parameters:
      - PublicSubnet
    ParameterLabels:
      PublicSubnet:
        default: "Worker Subnet"
      HostInstanceType:
        default: "Worker Instance Type"

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
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: RHELPublicSubnet

  RHELNatGatewayEIP:
    Type: AWS::EC2::EIP
    DependsOn: RHELGatewayAttachment
    Properties:
      Domain: vpc
  RHELNatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt RHELNatGatewayEIP.AllocationId
      SubnetId: !Ref RHELPublicSubnet

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
      LaunchTemplateName: ${stack_name}-launch-template
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
        LaunchTemplateName: ${stack_name}-launch-template
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
          echo "====== Running DNF Install ======" | tee -a /tmp/init_output.txt
          if ! ( sudo lsblk | grep 'xvdc' ); then
              echo "/dev/xvdc device not found, assuming this is metal host, skipping LVM configuration" |& tee -a /tmp/init_output.txt
              exit 0
          fi
          sudo dnf install -y lvm2 |& tee -a /tmp/init_output.txt

          # NOTE: wrapping script vars with {} since the cloudformation will see
          # them as cloudformation vars instead.
          echo "====== Creating PV ======" | tee -a /tmp/init_output.txt
          sudo pvcreate "\${HostDeviceName}" |& tee -a /tmp/init_output.txt
          echo "====== Creating VG ======" | tee -a /tmp/init_output.txt
          sudo vgcreate rhel "\${HostDeviceName}" |& tee -a /tmp/init_output.txt

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

if aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
    --query "Stacks[].Outputs[?OutputKey == 'InstanceId'].OutputValue" > /dev/null; then
        echo "Appears that stack ${stack_name} already exists"

        aws --region $REGION cloudformation delete-stack --stack-name "${stack_name}"
        echo "Deleted stack ${stack_name}"

        aws --region $REGION cloudformation wait stack-delete-complete --stack-name "${stack_name}"
        echo "Waited for stack-delete-complete ${stack_name}"
fi

echo -e "==== Start to create rhel host ===="
echo "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region "$REGION" cloudformation create-stack --stack-name "${stack_name}" \
    --template-body "file://${cf_tpl_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HostInstanceType,ParameterValue="${instance_type}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=HostDeviceName,ParameterValue="${host_device_name}" \
        ParameterKey=EC2Type,ParameterValue="${ec2Type}" \
        ParameterKey=PublicKeyString,ParameterValue="$(cat ${CLUSTER_PROFILE_DIR}/ssh-publickey)"

echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}"
echo "Waited for stack"

echo "$stack_name" > "${SHARED_DIR}/rhel_host_stack_name"
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

echo "Waiting up to 5 min for RHEL host to be up."
timeout 5m aws --region "${REGION}" ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}"
