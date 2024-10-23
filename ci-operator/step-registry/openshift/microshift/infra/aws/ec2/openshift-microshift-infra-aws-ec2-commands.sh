#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_AWS_EC2_FAILURE

# Available regions to create the stack. These are ordered by price per instance per hour as of 07/2024.
declare regions=(us-west-2 us-east-1 eu-central-1)
# Use the first region in the list, as it should be the most stable, as the one where to push/pull caching
# results. This is done because of costs as cross-region traffic is expensive.
CACHE_REGION="${regions[0]}"

# This map should be extended everytime AMIs from different regions/architectures/os versions
# are added.
# Command to get AMIs without using WebUI/AWS console:
# aws ec2 describe-images --region $region --filters 'Name=name,Values=RHEL-9.*' --query 'Images[*].[Name,ImageId,Architecture]' --output text | sort --reverse
declare -A ami_map=(
  [us-east-1,x86_64,rhel-9.2]=ami-078cb4217e3046abf  # RHEL-9.2.0_HVM-20240521-x86_64-93-Hourly2-GP3
  [us-east-1,arm64,rhel-9.2]=ami-04c1dfc4f324c64b2   # RHEL-9.2.0_HVM-20240521-arm64-93-Hourly2-GP3
  [us-east-1,x86_64,rhel-9.3]=ami-0fc8883cbe9d895c8  # RHEL-9.3.0_HVM-20240229-x86_64-27-Hourly2-GP3
  [us-east-1,arm64,rhel-9.3]=ami-0677a1dd1ad031d74   # RHEL-9.3.0_HVM-20240229-arm64-27-Hourly2-GP3
  [us-east-1,x86_64,rhel-9.4]=ami-0583d8c7a9c35822c  # RHEL-9.4.0_HVM-20240605-x86_64-82-Hourly2-GP3
  [us-east-1,arm64,rhel-9.4]=ami-07472131ec292b5da   # RHEL-9.4.0_HVM-20240605-arm64-82-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.2]=ami-0e4e5e5727c2a7a33  # RHEL-9.2.0_HVM-20240521-x86_64-93-Hourly2-GP3
  [us-west-2,arm64,rhel-9.2]=ami-0538b6fddb813b795   # RHEL-9.2.0_HVM-20240521-arm64-93-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.3]=ami-0c2f1f1137a85327e  # RHEL-9.3.0_HVM-20240229-x86_64-27-Hourly2-GP3
  [us-west-2,arm64,rhel-9.3]=ami-04379fa947a959c92   # RHEL-9.3.0_HVM-20240229-arm64-27-Hourly2-GP3
  [us-west-2,x86_64,rhel-9.4]=ami-0423fca164888b941  # RHEL-9.4.0_HVM-20240605-x86_64-82-Hourly2-GP3
  [us-west-2,arm64,rhel-9.4]=ami-05b40ce1c0e236ef2   # RHEL-9.4.0_HVM-20240605-arm64-82-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.2]=ami-0d4c002fec950de2b  # RHEL-9.2.0_HVM-20240521-x86_64-93-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.2]=ami-07dda6169c6afa927   # RHEL-9.2.0_HVM-20240521-arm64-93-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.3]=ami-0955dc0147853401b  # RHEL-9.3.0_HVM-20240229-x86_64-27-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.3]=ami-0ea2a765094f230d5   # RHEL-9.3.0_HVM-20240229-arm64-27-Hourly2-GP3
  [eu-central-1,x86_64,rhel-9.4]=ami-007c3072df8eb6584  # RHEL-9.4.0_HVM-20240605-x86_64-82-Hourly2-GP3
  [eu-central-1,arm64,rhel-9.4]=ami-02212921a6e889ed6   # RHEL-9.4.0_HVM-20240605-arm64-82-Hourly2-GP3
)

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"
if [ -f "${MICROSHIFT_CLUSTERBOT_SETTINGS}" ]; then
  : Overriding step defaults by sourcing clusterbot settings
  # shellcheck disable=SC1090
  source "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
fi

# All graviton instances have a lower case g in the family part. Using
# this we avoid adding the full map here.
ARCH="x86_64"
if [[ "${EC2_INSTANCE_TYPE%.*}" =~ .*"g".* ]]; then
  ARCH="arm64"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=""
JOB_NAME="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${JOB_NAME}"
cf_tpl_file="${SHARED_DIR}/${JOB_NAME}-cf-tpl.yaml"

ec2Type="VirtualMachine"
if [[ "$EC2_INSTANCE_TYPE" =~ metal ]]; then
  ec2Type="MetalMachine"
fi
instance_type=${EC2_INSTANCE_TYPE}

function save_stack_events_to_shared()
{
  set +o errexit
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.${REGION}.json"
  set -o errexit
}

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
     Throughput: 750
     Iops: 6000
   VirtualMachine:
     PrimaryVolumeSize: "200"
     SecondaryVolumeSize: "10"
     Throughput: 125
     Iops: 3000
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

  RHELVPCIPv6Cidr:
    Type: AWS::EC2::VPCCidrBlock
    Properties:
      AmazonProvidedIpv6CidrBlock: true
      VpcId: !Ref RHELVPC

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

  RHELPublicSubnet:
    Type: AWS::EC2::Subnet
    DependsOn: RHELVPCIPv6Cidr
    Properties:
      VpcId: !Ref RHELVPC
      CidrBlock: !Ref PublicSubnetCidr
      MapPublicIpOnLaunch: true
      Ipv6CidrBlock: !Select [ 0, !Cidr [ !Select [ 0, !GetAtt RHELVPC.Ipv6CidrBlocks], 256, 64 ]]
      AssignIpv6AddressOnCreation: true
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

  RHELPublicRouteIpv6:
    Type: AWS::EC2::Route
    DependsOn: RHELGatewayAttachment
    Properties:
      RouteTableId: !Ref RHELRouteTable
      DestinationIpv6CidrBlock: "::/0"
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
      - IpProtocol: icmpv6
        FromPort: -1
        ToPort: -1
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 5353
        ToPort: 5353
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5353
        ToPort: 5353
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 5678
        ToPort: 5678
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5678
        ToPort: 5678
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 6443
        ToPort: 6443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 6443
        ToPort: 6443
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 30000
        ToPort: 32767
        CidrIpv6: ::/0
      - IpProtocol: udp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      - IpProtocol: udp
        FromPort: 30000
        ToPort: 32767
        CidrIpv6: ::/0
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
            Iops: !FindInMap [VolumeSize, !Ref EC2Type, Iops]
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



for aws_region in "${regions[@]}"; do
  REGION="${aws_region}"
  echo "Current region: ${REGION}"
  ami_id="${ami_map[$REGION,$ARCH,$MICROSHIFT_OS]}"

  if aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
    --query "Stacks[].Outputs[?OutputKey == 'InstanceId'].OutputValue" > /dev/null; then
      echo "Appears that stack ${stack_name} already exists"
      aws --region $REGION cloudformation delete-stack --stack-name "${stack_name}"
      echo "Deleted stack ${stack_name}"
      aws --region $REGION cloudformation wait stack-delete-complete --stack-name "${stack_name}"
      echo "Waited for stack-delete-complete ${stack_name}"
  fi

  echo -e "${REGION} ${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

  if aws --region "$REGION" cloudformation create-stack --stack-name "${stack_name}" \
    --template-body "file://${cf_tpl_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HostInstanceType,ParameterValue="${instance_type}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=EC2Type,ParameterValue="${ec2Type}" \
        ParameterKey=PublicKeyString,ParameterValue="$(cat ${CLUSTER_PROFILE_DIR}/ssh-publickey)" && \
    aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}"; then

      echo "Stack created"
      set -e

      scp "${INSTANCE_PREFIX}:/tmp/init_output.txt" "${ARTIFACT_DIR}/init_ec2_output.txt"
      
      # shellcheck disable=SC2016
      INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text)"
      echo "Instance ${INSTANCE_ID}"
      echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-id"
      # shellcheck disable=SC2016
      HOST_PUBLIC_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[].Outputs[?OutputKey == `PublicIp`].OutputValue' --output text)"
      # shellcheck disable=SC2016
      HOST_PRIVATE_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" --query 'Stacks[].Outputs[?OutputKey == `PrivateIp`].OutputValue' --output text)"
      # shellcheck disable=SC2016
      IPV6_ADDRESS=$(aws --region "${REGION}" ec2 describe-instances --instance-id "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].[Ipv6Addresses[*].Ipv6Address]' --output text)

      echo "${HOST_PUBLIC_IP}" > "${SHARED_DIR}/public_address"
      echo "${HOST_PRIVATE_IP}" > "${SHARED_DIR}/private_address"
      echo "${IPV6_ADDRESS}" > "${SHARED_DIR}/public_ipv6_address"
      echo "ec2-user" > "${SHARED_DIR}/ssh_user"
      echo "${CACHE_REGION}" > "${SHARED_DIR}/cache_region"

      echo "Waiting up to 5 min for RHEL host to be up."
      timeout 5m aws --region "${REGION}" ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}"
      exit 0
  fi
  save_stack_events_to_shared
done

echo "Unable to create stack in any of the regions."
exit 1
