#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${REGION:-$LEASED_RESOURCE}"
JOB_NAME="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${JOB_NAME}"
cf_tpl_file="${SHARED_DIR}/${JOB_NAME}-cf-tpl.yaml"

instance_type="${EC2_INSTANCE_TYPE}"

function save_stack_events_to_shared() {
  set +o errexit
  aws --region "${REGION}" cloudformation describe-stack-events \
    --stack-name "${stack_name}" --output json \
    > "${SHARED_DIR}/stack-events-${stack_name}.json" 2>/dev/null
  set -o errexit
}

trap 'save_stack_events_to_shared' EXIT TERM INT

echo "ubuntu" > "${SHARED_DIR}/ssh_user"
echo "AMI: ${EC2_AMI}"

cat > "${cf_tpl_file}" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: EC2 instance for running kind clusters

Parameters:
  VpcCidr:
    Default: 10.192.0.0/16
    Type: String
  SubnetCidr:
    Default: 10.192.10.0/24
    Type: String
  AmiId:
    Type: AWS::EC2::Image::Id
  InstanceType:
    Default: t3.large
    Type: String
  Machinename:
    Type: String
    Default: kind-ec2-host
  PublicKeyString:
    Type: String

Resources:
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      EnableDnsHostnames: true
      EnableDnsSupport: true

  InternetGateway:
    Type: AWS::EC2::InternetGateway

  GatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway

  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Ref SubnetCidr
      MapPublicIpOnLaunch: true

  RouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC

  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: GatewayAttachment
    Properties:
      RouteTableId: !Ref RouteTable
      DestinationCidrBlock: "0.0.0.0/0"
      GatewayId: !Ref InternetGateway

  SubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref RouteTable
      SubnetId: !Ref PublicSubnet

  SecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: kind EC2 host
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      VpcId: !Ref VPC

  IamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: Allow
          Principal:
            Service: ec2.amazonaws.com
          Action: sts:AssumeRole
      Path: "/"

  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Path: "/"
      Roles:
      - !Ref IamRole

  Instance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref InstanceType
      IamInstanceProfile: !Ref InstanceProfile
      BlockDeviceMappings:
      - DeviceName: /dev/sda1
        Ebs:
          VolumeSize: 50
          VolumeType: gp3
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt SecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet
      Tags:
      - Key: Name
        Value: !Ref Machinename
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash -xe
          exec > /tmp/init_output.txt 2>&1

          echo "=== Authorizing SSH key ==="
          echo "\${PublicKeyString}" >> /home/ubuntu/.ssh/authorized_keys

          echo "=== Installing Docker ==="
          apt-get update
          apt-get install -y docker.io
          systemctl enable --now docker
          usermod -aG docker ubuntu

          echo "=== Installing kind ==="
          curl -sSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
          chmod +x /usr/local/bin/kind

          echo "=== Installing kubectl ==="
          curl -sSLo /usr/local/bin/kubectl https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
          chmod +x /usr/local/bin/kubectl

          echo "=== Tuning sysctl ==="
          echo "fs.inotify.max_user_watches = 65536" >> /etc/sysctl.conf
          echo "fs.inotify.max_user_instances = 8192" >> /etc/sysctl.conf
          sysctl --system

          echo "=== Init complete ==="

Outputs:
  InstanceId:
    Value: !Ref Instance
  PublicIp:
    Value: !GetAtt Instance.PublicIp
EOF

if aws --region "${REGION}" cloudformation describe-stacks \
    --stack-name "${stack_name}" > /dev/null 2>&1; then
  echo "Stack ${stack_name} already exists, deleting..."
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${stack_name}"
  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${stack_name}"
fi

echo "Creating stack ${stack_name}..."
echo "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${stack_name}" \
  --template-body "file://${cf_tpl_file}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=InstanceType,ParameterValue="${instance_type}" \
    ParameterKey=Machinename,ParameterValue="${stack_name}" \
    ParameterKey=AmiId,ParameterValue="${EC2_AMI}" \
    ParameterKey=PublicKeyString,ParameterValue="$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")"

echo "Waiting for stack creation..."
if ! aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}"; then
  echo "ERROR: Stack creation failed. Stack events:"
  aws --region "${REGION}" cloudformation describe-stack-events \
    --stack-name "${stack_name}" --output json
  exit 1
fi

INSTANCE_ID=$(aws --region "${REGION}" cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
HOST_PUBLIC_IP=$(aws --region "${REGION}" cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)

echo "${HOST_PUBLIC_IP}" > "${SHARED_DIR}/public_address"
echo "Instance ${INSTANCE_ID} at ${HOST_PUBLIC_IP}"

echo "Waiting for instance to be ready..."
timeout 5m aws --region "${REGION}" ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}"
echo "Instance ready"
