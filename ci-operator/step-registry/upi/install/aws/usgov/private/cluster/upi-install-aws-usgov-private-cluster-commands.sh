#!/bin/bash
set -euo pipefail

teardown() {
    local exit_code=$?
    echo "$exit_code" > "${SHARED_DIR}/install-status.txt"
    save_stack_events_to_artifacts
    prepare_next_steps
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
    exit $exit_code
}

trap teardown EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export PATH=/tmp:${PATH}
GATHER_BOOTSTRAP_ARGS=
NEW_STACKS=$(mktemp)

INSTALL_DIR=/tmp/installer
mkdir ${INSTALL_DIR}

function populate_artifact_dir()
{
  set +e
  current_time=$(date +%s)
  echo "Copying log bundle..."
  cp "${INSTALL_DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${INSTALL_DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install-${current_time}.log"
  if [ -f "${INSTALL_DIR}/terraform.txt" ]; then
    sed -i '
      s/password: .*/password: REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' "${INSTALL_DIR}/terraform.txt"
    tar -czvf "${ARTIFACT_DIR}/terraform-${current_time}.tar.gz" --remove-files "${INSTALL_DIR}/terraform.txt"
  fi
  if [ -d "${INSTALL_DIR}/.clusterapi_output" ]; then
    echo "Copying Cluster API generated manifests..."
    mkdir -p "${ARTIFACT_DIR}/clusterapi_output-${current_time}"
    cp -rpv "${INSTALL_DIR}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/clusterapi_output-${current_time}" 2>/dev/null
  fi
  set -e
}

function prepare_next_steps() {
  set +e
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  cp \
      -t "${SHARED_DIR}" \
      "${INSTALL_DIR}/auth/kubeconfig" \
      "${INSTALL_DIR}/auth/kubeadmin-password" \
      "${INSTALL_DIR}/metadata.json"
  set -e
}

function add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${INSTALL_DIR} gather bootstrap --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi
  return 1
}

function save_stack_events_to_artifacts()
{
  set +o errexit
  echo "saving stack events to artifacts dir..."
  while read -r stack_name
  do
    echo "processing $stack_name ..."
    aws --region ${AWS_REGION} cloudformation describe-stack-events --stack-name ${stack_name} --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.json"
  done < "${NEW_STACKS}"
  set -o errexit
}

# Write the private-only infra CloudFormation template (internal NLB, no external)
function write_private_infra_template() {
  local outfile="$1"
  cat > "${outfile}" <<'INFRA_TEMPLATE_EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs) - Private Only

Parameters:
  ClusterName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Cluster name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, representative cluster name to use for host names and other identifying names.
    Type: String
  InfrastructureName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Infrastructure name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, unique cluster ID used to tag cloud resources and identify items owned or used by the cluster.
    Type: String
  HostedZoneName:
    Description: The Route53 zone to register the targets with, such as example.com. Omit the trailing period.
    Type: String
    Default: "example.com"
  PrivateSubnets:
    Description: The internal subnets.
    Type: List<AWS::EC2::Subnet::Id>
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - ClusterName
      - InfrastructureName
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcId
      - PrivateSubnets
    - Label:
        default: "DNS"
      Parameters:
      - HostedZoneName
    ParameterLabels:
      ClusterName:
        default: "Cluster Name"
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      PrivateSubnets:
        default: "Private Subnets"
      HostedZoneName:
        default: "Private Hosted Zone Name"

Resources:
  IntApiElb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Join ["-", [!Ref InfrastructureName, "int"]]
      Scheme: internal
      IpAddressType: ipv4
      Subnets: !Ref PrivateSubnets
      Type: network

  IntDns:
    Type: "AWS::Route53::HostedZone"
    Properties:
      HostedZoneConfig:
        Comment: "Managed by CloudFormation"
      Name: !Join [".", [!Ref ClusterName, !Ref HostedZoneName]]
      HostedZoneTags:
      - Key: Name
        Value: !Join ["-", [!Ref InfrastructureName, "int"]]
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "owned"
      VPCs:
      - VPCId: !Ref VpcId
        VPCRegion: !Ref "AWS::Region"

  InternalApiServerRecord:
    Type: AWS::Route53::RecordSetGroup
    Properties:
      Comment: Alias record for the API server (internal only)
      HostedZoneId: !Ref IntDns
      RecordSets:
      - Name:
          !Join [
            ".",
            ["api", !Ref ClusterName, !Join ["", [!Ref HostedZoneName, "."]]],
          ]
        Type: A
        AliasTarget:
          HostedZoneId: !GetAtt IntApiElb.CanonicalHostedZoneID
          DNSName: !GetAtt IntApiElb.DNSName
      - Name:
          !Join [
            ".",
            ["api-int", !Ref ClusterName, !Join ["", [!Ref HostedZoneName, "."]]],
          ]
        Type: A
        AliasTarget:
          HostedZoneId: !GetAtt IntApiElb.CanonicalHostedZoneID
          DNSName: !GetAtt IntApiElb.DNSName

  InternalApiListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      DefaultActions:
      - Type: forward
        TargetGroupArn:
          Ref: InternalApiTargetGroup
      LoadBalancerArn:
        Ref: IntApiElb
      Port: 6443
      Protocol: TCP

  InternalApiTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      HealthCheckIntervalSeconds: 10
      HealthCheckPath: "/readyz"
      HealthCheckPort: 6443
      HealthCheckProtocol: HTTPS
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Port: 6443
      Protocol: TCP
      TargetType: ip
      VpcId:
        Ref: VpcId
      TargetGroupAttributes:
      - Key: deregistration_delay.timeout_seconds
        Value: 60

  InternalServiceInternalListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      DefaultActions:
      - Type: forward
        TargetGroupArn:
          Ref: InternalServiceTargetGroup
      LoadBalancerArn:
        Ref: IntApiElb
      Port: 22623
      Protocol: TCP

  InternalServiceTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      HealthCheckIntervalSeconds: 10
      HealthCheckPath: "/healthz"
      HealthCheckPort: 22623
      HealthCheckProtocol: HTTPS
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Port: 22623
      Protocol: TCP
      TargetType: ip
      VpcId:
        Ref: VpcId
      TargetGroupAttributes:
      - Key: deregistration_delay.timeout_seconds
        Value: 60

  RegisterTargetLambdaIamRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Join ["-", [!Ref InfrastructureName, "nlb", "lambda", "role"]]
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "lambda.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"
      Policies:
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "master", "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action:
              [
                "elasticloadbalancing:RegisterTargets",
                "elasticloadbalancing:DeregisterTargets",
              ]
            Resource: !Ref InternalApiTargetGroup
          - Effect: "Allow"
            Action:
              [
                "elasticloadbalancing:RegisterTargets",
                "elasticloadbalancing:DeregisterTargets",
              ]
            Resource: !Ref InternalServiceTargetGroup

  RegisterNlbIpTargets:
    Type: "AWS::Lambda::Function"
    Properties:
      Handler: "index.handler"
      Role:
        Fn::GetAtt:
        - "RegisterTargetLambdaIamRole"
        - "Arn"
      Code:
        ZipFile: |
          import json
          import boto3
          import cfnresponse
          def handler(event, context):
            elb = boto3.client('elbv2')
            if event['RequestType'] == 'Delete':
              elb.deregister_targets(TargetGroupArn=event['ResourceProperties']['TargetArn'],Targets=[{'Id': event['ResourceProperties']['TargetIp']}])
            elif event['RequestType'] == 'Create':
              elb.register_targets(TargetGroupArn=event['ResourceProperties']['TargetArn'],Targets=[{'Id': event['ResourceProperties']['TargetIp']}])
            responseData = {}
            cfnresponse.send(event, context, cfnresponse.SUCCESS, responseData, event['ResourceProperties']['TargetArn']+event['ResourceProperties']['TargetIp'])
      Runtime: "python3.11"
      Timeout: 120

  RegisterSubnetTagsLambdaIamRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Join ["-", [!Ref InfrastructureName, "subnet-tags-lambda-role"]]
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "lambda.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"
      Policies:
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "subnet-tagging-policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action:
              [
                "ec2:DeleteTags",
                "ec2:CreateTags"
              ]
            Resource: !Sub "arn:${AWS::Partition}:ec2:*:*:subnet/*"
          - Effect: "Allow"
            Action:
              [
                "ec2:DescribeSubnets",
                "ec2:DescribeTags"
              ]
            Resource: "*"

  RegisterSubnetTags:
    Type: "AWS::Lambda::Function"
    Properties:
      Handler: "index.handler"
      Role:
        Fn::GetAtt:
        - "RegisterSubnetTagsLambdaIamRole"
        - "Arn"
      Code:
        ZipFile: |
          import json
          import boto3
          import cfnresponse
          def handler(event, context):
            ec2_client = boto3.client('ec2')
            if event['RequestType'] == 'Delete':
              for subnet_id in event['ResourceProperties']['Subnets']:
                ec2_client.delete_tags(Resources=[subnet_id], Tags=[{'Key': 'kubernetes.io/cluster/' + event['ResourceProperties']['InfrastructureName']}]);
            elif event['RequestType'] == 'Create':
              for subnet_id in event['ResourceProperties']['Subnets']:
                ec2_client.create_tags(Resources=[subnet_id], Tags=[{'Key': 'kubernetes.io/cluster/' + event['ResourceProperties']['InfrastructureName'], 'Value': 'shared'}]);
            responseData = {}
            cfnresponse.send(event, context, cfnresponse.SUCCESS, responseData, event['ResourceProperties']['InfrastructureName']+event['ResourceProperties']['Subnets'][0])
      Runtime: "python3.11"
      Timeout: 120

  RegisterPrivateSubnetTags:
    Type: Custom::SubnetRegister
    Properties:
      ServiceToken: !GetAtt RegisterSubnetTags.Arn
      InfrastructureName: !Ref InfrastructureName
      Subnets: !Ref PrivateSubnets

Outputs:
  PrivateHostedZoneId:
    Description: Hosted zone ID for the private DNS, which is required for private records.
    Value: !Ref IntDns
  InternalApiLoadBalancerName:
    Description: Full name of the internal API load balancer.
    Value: !GetAtt IntApiElb.LoadBalancerFullName
  ApiServerDnsName:
    Description: Full hostname of the API server, which is required for the Ignition config files.
    Value: !Join [".", ["api-int", !Ref ClusterName, !Ref HostedZoneName]]
  RegisterNlbIpTargetsLambda:
    Description: Lambda ARN useful to help register or deregister IP targets for these load balancers.
    Value: !GetAtt RegisterNlbIpTargets.Arn
  InternalApiTargetGroupArn:
    Description: ARN of the internal API target group.
    Value: !Ref InternalApiTargetGroup
  InternalServiceTargetGroupArn:
    Description: ARN of the internal service target group.
    Value: !Ref InternalServiceTargetGroup
INFRA_TEMPLATE_EOF
}

# Write the private bootstrap CloudFormation template (private subnet, no public IP)
function write_private_bootstrap_template() {
  local outfile="$1"
  cat > "${outfile}" <<'BOOTSTRAP_TEMPLATE_EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Bootstrap (EC2 Instance, Security Groups and IAM) - Private Only

Parameters:
  InfrastructureName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Infrastructure name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, unique cluster ID used to tag cloud resources and identify items owned or used by the cluster.
    Type: String
  RhcosAmi:
    Description: Current Red Hat Enterprise Linux CoreOS AMI to use for bootstrap.
    Type: AWS::EC2::Image::Id
  AllowedBootstrapSshCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/([0-9]|1[0-9]|2[0-9]|3[0-2]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/0-32.
    Default: 0.0.0.0/0
    Description: CIDR block to allow SSH access to the bootstrap node.
    Type: String
  PrivateSubnet:
    Description: The private subnet to launch the bootstrap node into.
    Type: AWS::EC2::Subnet::Id
  MasterSecurityGroupId:
    Description: The master security group ID for registering temporary rules.
    Type: AWS::EC2::SecurityGroup::Id
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id
  BootstrapIgnitionLocation:
    Default: s3://my-s3-bucket/bootstrap.ign
    Description: Ignition config file location.
    Type: String
  AutoRegisterELB:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Do you want to invoke NLB registration, which requires a Lambda ARN parameter?
    Type: String
  RegisterNlbIpTargetsLambdaArn:
    Description: ARN for NLB IP target registration lambda.
    Type: String
  InternalApiTargetGroupArn:
    Description: ARN for internal API load balancer target group.
    Type: String
  InternalServiceTargetGroupArn:
    Description: ARN for internal service load balancer target group.
    Type: String
  BootstrapInstanceType:
    Description: Instance type for the bootstrap EC2 instance
    Default: "i3.large"
    Type: String

Conditions:
  DoRegistration: !Equals ["yes", !Ref AutoRegisterELB]

Resources:
  BootstrapIamRole:
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
      Policies:
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "bootstrap", "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action: "ec2:Describe*"
            Resource: "*"
          - Effect: "Allow"
            Action: "ec2:AttachVolume"
            Resource: "*"
          - Effect: "Allow"
            Action: "ec2:DetachVolume"
            Resource: "*"
          - Effect: "Allow"
            Action: "s3:GetObject"
            Resource: "*"

  BootstrapInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "BootstrapIamRole"

  BootstrapSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Cluster Bootstrap Security Group
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: !Ref AllowedBootstrapSshCidr
      - IpProtocol: tcp
        ToPort: 19531
        FromPort: 19531
        CidrIp: 0.0.0.0/0
      VpcId: !Ref VpcId

  BootstrapInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      IamInstanceProfile: !Ref BootstrapInstanceProfile
      InstanceType: !Ref BootstrapInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "false"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "BootstrapSecurityGroup"
        - !Ref "MasterSecurityGroupId"
        SubnetId: !Ref "PrivateSubnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"replace":{"source":"${S3Loc}"}},"version":"3.1.0"}}'
        - {
          S3Loc: !Ref BootstrapIgnitionLocation
        }

  RegisterBootstrapInternalApiTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalApiTargetGroupArn
      TargetIp: !GetAtt BootstrapInstance.PrivateIp

  RegisterBootstrapInternalServiceTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalServiceTargetGroupArn
      TargetIp: !GetAtt BootstrapInstance.PrivateIp

Outputs:
  BootstrapInstanceId:
    Description: Bootstrap Instance ID.
    Value: !Ref BootstrapInstance
  BootstrapPrivateIp:
    Description: The bootstrap node private IP address.
    Value: !GetAtt BootstrapInstance.PrivateIp
BOOTSTRAP_TEMPLATE_EOF
}

# Write the private master nodes CloudFormation template (internal target groups only)
function write_private_control_plane_template() {
  local outfile="$1"
  cat > "${outfile}" <<'CONTROL_PLANE_TEMPLATE_EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Node Launch (EC2 master instances) - Private Only

Parameters:
  InfrastructureName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Infrastructure name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, unique cluster ID used to tag nodes for the kubelet cloud provider.
    Type: String
  RhcosAmi:
    Description: Current Red Hat Enterprise Linux CoreOS AMI to use for bootstrap.
    Type: AWS::EC2::Image::Id
  Master0Subnet:
    Description: The subnets, recommend private, to launch the master nodes into.
    Type: AWS::EC2::Subnet::Id
  Master1Subnet:
    Description: The subnets, recommend private, to launch the master nodes into.
    Type: AWS::EC2::Subnet::Id
  Master2Subnet:
    Description: The subnets, recommend private, to launch the master nodes into.
    Type: AWS::EC2::Subnet::Id
  MasterSecurityGroupId:
    Description: The master security group ID to associate with master nodes.
    Type: AWS::EC2::SecurityGroup::Id
  IgnitionLocation:
    Default: https://api-int.$CLUSTER_NAME.$DOMAIN:22623/config/master
    Description: Ignition config file location.
    Type: String
  CertificateAuthorities:
    Default: data:text/plain;charset=utf-8;base64,ABC...xYz==
    Description: Base64 encoded certificate authority string to use.
    Type: String
  MasterInstanceProfileName:
    Description: IAM profile to associate with master nodes.
    Type: String
  MasterInstanceType:
    Default: m6i.xlarge
    Type: String
  AutoRegisterELB:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Do you want to invoke NLB registration, which requires a Lambda ARN parameter?
    Type: String
  RegisterNlbIpTargetsLambdaArn:
    Description: ARN for NLB IP target registration lambda. Supply the value from the cluster infrastructure or select "no" for AutoRegisterELB.
    Type: String
  InternalApiTargetGroupArn:
    Description: ARN for internal API load balancer target group. Supply the value from the cluster infrastructure or select "no" for AutoRegisterELB.
    Type: String
  InternalServiceTargetGroupArn:
    Description: ARN for internal service load balancer target group. Supply the value from the cluster infrastructure or select "no" for AutoRegisterELB.
    Type: String

Conditions:
  DoRegistration: !Equals ["yes", !Ref AutoRegisterELB]

Resources:
  Master0:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      BlockDeviceMappings:
      - DeviceName: /dev/xvda
        Ebs:
          VolumeSize: "120"
          VolumeType: "gp3"
      IamInstanceProfile: !Ref MasterInstanceProfileName
      InstanceType: !Ref MasterInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "false"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "MasterSecurityGroupId"
        SubnetId: !Ref "Master0Subnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"merge":[{"source":"${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

  RegisterMaster0InternalApiTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalApiTargetGroupArn
      TargetIp: !GetAtt Master0.PrivateIp

  RegisterMaster0InternalServiceTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalServiceTargetGroupArn
      TargetIp: !GetAtt Master0.PrivateIp

  Master1:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      BlockDeviceMappings:
      - DeviceName: /dev/xvda
        Ebs:
          VolumeSize: "120"
          VolumeType: "gp3"
      IamInstanceProfile: !Ref MasterInstanceProfileName
      InstanceType: !Ref MasterInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "false"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "MasterSecurityGroupId"
        SubnetId: !Ref "Master1Subnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"merge":[{"source":"${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

  RegisterMaster1InternalApiTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalApiTargetGroupArn
      TargetIp: !GetAtt Master1.PrivateIp

  RegisterMaster1InternalServiceTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalServiceTargetGroupArn
      TargetIp: !GetAtt Master1.PrivateIp

  Master2:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      BlockDeviceMappings:
      - DeviceName: /dev/xvda
        Ebs:
          VolumeSize: "120"
          VolumeType: "gp3"
      IamInstanceProfile: !Ref MasterInstanceProfileName
      InstanceType: !Ref MasterInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "false"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "MasterSecurityGroupId"
        SubnetId: !Ref "Master2Subnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"merge":[{"source":"${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

  RegisterMaster2InternalApiTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalApiTargetGroupArn
      TargetIp: !GetAtt Master2.PrivateIp

  RegisterMaster2InternalServiceTarget:
    Condition: DoRegistration
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref InternalServiceTargetGroupArn
      TargetIp: !GetAtt Master2.PrivateIp

Outputs:
  PrivateIPs:
    Description: The control-plane node private IP addresses.
    Value:
      !Join [
        ",",
        [!GetAtt Master0.PrivateIp, !GetAtt Master1.PrivateIp, !GetAtt Master2.PrivateIp]
      ]
CONTROL_PLANE_TEMPLATE_EOF
}

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

cp "$(command -v openshift-install)" /tmp

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)

export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
export PULL_SECRET_PATH
export OPENSHIFT_INSTALL_INVOKER
export AWS_SHARED_CREDENTIALS_FILE
export EXPIRATION_DATE

mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/
cp ${SHARED_DIR}/install-config.yaml ${INSTALL_DIR}/install-config.yaml
export PATH=${HOME}/.local/bin:${PATH}

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: ${ocp_version}"
rm /tmp/pull-secret

pushd ${INSTALL_DIR}

base_domain=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'baseDomain')
AWS_REGION=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'platform.aws.region')
CLUSTER_NAME=$(yq-go r "${INSTALL_DIR}/install-config.yaml" 'metadata.name')

echo ${AWS_REGION} > ${SHARED_DIR}/AWS_REGION
echo ${CLUSTER_NAME} > ${SHARED_DIR}/CLUSTER_NAME
export AWS_DEFAULT_REGION="${AWS_REGION}"
MACHINE_CIDR=10.0.0.0/16
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

# --- Step 1: Read VPC info from SHARED_DIR (created by aws-provision-vpc-shared) ---
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")
PRIVATE_SUBNETS_RAW=$(sed "s/'//g" "${SHARED_DIR}/private_subnet_ids" | tr -d '[]' | tr -d ' ')
PRIVATE_SUBNET_0=$(echo "${PRIVATE_SUBNETS_RAW}" | cut -d, -f1)
PRIVATE_SUBNET_1=$(echo "${PRIVATE_SUBNETS_RAW}" | cut -d, -f2)
PRIVATE_SUBNET_2=$(echo "${PRIVATE_SUBNETS_RAW}" | cut -d, -f3)
if [[ -z "$PRIVATE_SUBNET_1" ]]; then PRIVATE_SUBNET_1=${PRIVATE_SUBNET_0}; fi
if [[ -z "$PRIVATE_SUBNET_2" ]]; then PRIVATE_SUBNET_2=${PRIVATE_SUBNET_0}; fi
PRIVATE_SUBNETS="${PRIVATE_SUBNET_0},${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}"

echo "VPC ID: ${VPC_ID}"
echo "Private subnets: ${PRIVATE_SUBNET_0}, ${PRIVATE_SUBNET_1}, ${PRIVATE_SUBNET_2}"

echo "install-config.yaml"
echo "-------------------"
cat ${INSTALL_DIR}/install-config.yaml | sed -E 's#(https?://[^:@/]+):[^:@/]+@#\1:XXX@#g' | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml

# --- Step 2: Generate manifests and ignition configs ---
echo "Generating manifests..."
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
openshift-install --dir=${INSTALL_DIR} create manifests
sed -i '/^  channel:/d' ${INSTALL_DIR}/manifests/cvo-overrides.yaml
rm -f ${INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f ${INSTALL_DIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
rm -f ${INSTALL_DIR}/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" ${INSTALL_DIR}/manifests/cluster-scheduler-02-config.yml

echo "Copying manifests from SHARED_DIR to installer directory:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  echo "  Copying ${manifest}"
  cp "${item}" "${INSTALL_DIR}/manifests/${manifest##manifest_}"
done < <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

echo "Creating ignition configs"
openshift-install --dir=${INSTALL_DIR} create ignition-configs &
wait "$!"

cp ${INSTALL_DIR}/bootstrap.ign ${SHARED_DIR}

# --- Step 3: Lookup RHCOS AMI ---
if openshift-install coreos print-stream-json 2>/tmp/err.txt >coreos.json; then
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.x86_64.images.aws.regions[$region].image' coreos.json)"
  if [[ "${OCP_ARCH}" == "arm64" ]]; then
    RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.aarch64.images.aws.regions[$region].image' coreos.json)"
  fi
else
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.amis[$region].hvm' /var/lib/openshift-install/rhcos.json)"
fi
echo "RHCOS AMI: ${RHCOS_AMI}"

INFRA_ID="$(jq -r .infraID ${INSTALL_DIR}/metadata.json)"
IGNITION_CA="$(jq '.ignition.security.tls.certificateAuthorities[0].source' ${INSTALL_DIR}/master.ign)"

# Define Stack names
INFRA_STACK_NAME=${CLUSTER_NAME}-infra
SECURITY_STACK_NAME=${CLUSTER_NAME}-security
BOOTSTRAP_STACK_NAME=${CLUSTER_NAME}-bootstrap
CONTROL_PLANE_STACK_NAME=${CLUSTER_NAME}-control-plane
COMPUTE_STACK_NAME_PREFIX=${CLUSTER_NAME}-compute

# --- Step 4: Create S3 bucket for bootstrap ignition ---
S3_BUCKET_URI="s3://${INFRA_STACK_NAME}"
aws s3 mb "${S3_BUCKET_URI}"
echo ${S3_BUCKET_URI} > ${SHARED_DIR}/s3_bucket_uri

S3_BOOTSTRAP_URI="${S3_BUCKET_URI}/bootstrap.ign"
aws s3 cp ${INSTALL_DIR}/bootstrap.ign "$S3_BOOTSTRAP_URI"

# --- Step 5: Create infra stack (private — internal NLB only, no external) ---
echo "Creating private infra stack (internal NLB only)..."
PRIVATE_INFRA_TEMPLATE=${ARTIFACT_DIR}/02_cluster_infra_private.yaml
write_private_infra_template "${PRIVATE_INFRA_TEMPLATE}"

cf_params_infra=${ARTIFACT_DIR}/cf_params_infra.json
add_param_to_json ClusterName "${CLUSTER_NAME}" "${cf_params_infra}"
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_infra}"
add_param_to_json HostedZoneName "${base_domain}" "${cf_params_infra}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_infra}"
add_param_to_json PrivateSubnets "${PRIVATE_SUBNETS}" "${cf_params_infra}"

echo "${INFRA_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${INFRA_STACK_NAME}" \
  --template-body "$(cat "${PRIVATE_INFRA_TEMPLATE}")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_infra} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${INFRA_STACK_NAME}" &
wait "$!"

INFRA_JSON="$(aws cloudformation describe-stacks --stack-name "${INFRA_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
NLB_IP_TARGETS_LAMBDA="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "RegisterNlbIpTargetsLambda").OutputValue')"
INTERNAL_API_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalApiTargetGroupArn").OutputValue')"
INTERNAL_SERVICE_TARGET_GROUP="$(echo "${INFRA_JSON}" | jq -r '.[] | select(.OutputKey == "InternalServiceTargetGroupArn").OutputValue')"

# --- Step 6: Create security stack ---
echo "Creating security stack..."
cf_params_security=${ARTIFACT_DIR}/cf_params_security.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_security}"
add_param_to_json VpcCidr "${MACHINE_CIDR}" "${cf_params_security}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_security}"
add_param_to_json PrivateSubnets "${PRIVATE_SUBNETS}" "${cf_params_security}"

echo "${SECURITY_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${SECURITY_STACK_NAME}" \
  --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/03_cluster_security.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_security} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${SECURITY_STACK_NAME}" &
wait "$!"

SECURITY_JSON="$(aws cloudformation describe-stacks --stack-name "${SECURITY_STACK_NAME}" \
  --query 'Stacks[].Outputs[]' --output json)"
MASTER_SECURITY_GROUP="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "MasterSecurityGroupId").OutputValue')"
MASTER_INSTANCE_PROFILE="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "MasterInstanceProfile").OutputValue')"
WORKER_SECURITY_GROUP="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "WorkerSecurityGroupId").OutputValue')"
WORKER_INSTANCE_PROFILE="$(echo "${SECURITY_JSON}" | jq -r '.[] | select(.OutputKey == "WorkerInstanceProfile").OutputValue')"

# --- Step 7: Create bootstrap stack (private subnet, no public IP) ---
echo "Creating bootstrap stack on private subnet..."
PRIVATE_BOOTSTRAP_TEMPLATE=${ARTIFACT_DIR}/04_cluster_bootstrap_private.yaml
write_private_bootstrap_template "${PRIVATE_BOOTSTRAP_TEMPLATE}"

cf_params_bootstrap=${ARTIFACT_DIR}/cf_params_bootstrap.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_bootstrap}"
add_param_to_json RhcosAmi "${RHCOS_AMI}" "${cf_params_bootstrap}"
add_param_to_json VpcId "${VPC_ID}" "${cf_params_bootstrap}"
add_param_to_json PrivateSubnet "${PRIVATE_SUBNET_0}" "${cf_params_bootstrap}"
add_param_to_json MasterSecurityGroupId "${MASTER_SECURITY_GROUP}" "${cf_params_bootstrap}"
add_param_to_json BootstrapIgnitionLocation "${S3_BOOTSTRAP_URI}" "${cf_params_bootstrap}"
add_param_to_json RegisterNlbIpTargetsLambdaArn "${NLB_IP_TARGETS_LAMBDA}" "${cf_params_bootstrap}"
add_param_to_json InternalApiTargetGroupArn "${INTERNAL_API_TARGET_GROUP}" "${cf_params_bootstrap}"
add_param_to_json InternalServiceTargetGroupArn "${INTERNAL_SERVICE_TARGET_GROUP}" "${cf_params_bootstrap}"
add_param_to_json BootstrapInstanceType "${BOOTSTRAP_INSTANCE_TYPE}" "${cf_params_bootstrap}"

echo "${BOOTSTRAP_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${BOOTSTRAP_STACK_NAME}" \
  --template-body "$(cat "${PRIVATE_BOOTSTRAP_TEMPLATE}")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters file://${cf_params_bootstrap} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

BOOTSTRAP_PRIVATE_IP="$(aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `BootstrapPrivateIp`].OutputValue' --output text)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_PRIVATE_IP}"

# --- Step 8: Create control plane stack (internal target groups only) ---
echo "Creating control plane stack..."
PRIVATE_CONTROL_PLANE_TEMPLATE=${ARTIFACT_DIR}/05_cluster_master_nodes_private.yaml
write_private_control_plane_template "${PRIVATE_CONTROL_PLANE_TEMPLATE}"

cf_params_control_plane=${ARTIFACT_DIR}/cf_params_control_plane.json
add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_control_plane}"
add_param_to_json RhcosAmi "${RHCOS_AMI}" "${cf_params_control_plane}"
add_param_to_json Master0Subnet "${PRIVATE_SUBNET_0}" "${cf_params_control_plane}"
add_param_to_json Master1Subnet "${PRIVATE_SUBNET_1}" "${cf_params_control_plane}"
add_param_to_json Master2Subnet "${PRIVATE_SUBNET_2}" "${cf_params_control_plane}"
add_param_to_json MasterSecurityGroupId "${MASTER_SECURITY_GROUP}" "${cf_params_control_plane}"
add_param_to_json IgnitionLocation "https://api-int.${CLUSTER_NAME}.${base_domain}:22623/config/master" "${cf_params_control_plane}"
add_param_to_json CertificateAuthorities "$(echo ${IGNITION_CA} | sed 's/"//g')" "${cf_params_control_plane}"
add_param_to_json MasterInstanceProfileName "${MASTER_INSTANCE_PROFILE}" "${cf_params_control_plane}"
add_param_to_json RegisterNlbIpTargetsLambdaArn "${NLB_IP_TARGETS_LAMBDA}" "${cf_params_control_plane}"
add_param_to_json InternalApiTargetGroupArn "${INTERNAL_API_TARGET_GROUP}" "${cf_params_control_plane}"
add_param_to_json InternalServiceTargetGroupArn "${INTERNAL_SERVICE_TARGET_GROUP}" "${cf_params_control_plane}"
add_param_to_json MasterInstanceType "${MASTER_INSTANCE_TYPE}" "${cf_params_control_plane}"

echo "${CONTROL_PLANE_STACK_NAME}" >> "${NEW_STACKS}"
aws cloudformation create-stack \
  --stack-name "${CONTROL_PLANE_STACK_NAME}" \
  --template-body "$(cat "${PRIVATE_CONTROL_PLANE_TEMPLATE}")" \
  --tags "${TAGS}" \
  --parameters file://${cf_params_control_plane} &
wait "$!"

aws cloudformation wait stack-create-complete --stack-name "${CONTROL_PLANE_STACK_NAME}" &
wait "$!"

CONTROL_PLANE_IPS="$(aws cloudformation describe-stacks --stack-name "${CONTROL_PLANE_STACK_NAME}" --query 'Stacks[].Outputs[?OutputKey == `PrivateIPs`].OutputValue' --output text)"
CONTROL_PLANE_0_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f1)"
CONTROL_PLANE_1_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f2)"
CONTROL_PLANE_2_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f3)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${CONTROL_PLANE_0_IP} --master ${CONTROL_PLANE_1_IP} --master ${CONTROL_PLANE_2_IP}"

# --- Step 9: Create compute worker stacks ---
echo "Creating compute stacks..."
for INDEX in 0 1 2
do
  SUBNET="PRIVATE_SUBNET_${INDEX}"
  COMPUTE_STACK_NAME=${COMPUTE_STACK_NAME_PREFIX}-${INDEX}

  cf_params_compute="${ARTIFACT_DIR}/cf_params_compute_${INDEX}.json"
  add_param_to_json InfrastructureName "${INFRA_ID}" "${cf_params_compute}"
  add_param_to_json RhcosAmi "${RHCOS_AMI}" "${cf_params_compute}"
  add_param_to_json Subnet "${!SUBNET}" "${cf_params_compute}"
  add_param_to_json WorkerSecurityGroupId "${WORKER_SECURITY_GROUP}" "${cf_params_compute}"
  add_param_to_json IgnitionLocation "https://api-int.${CLUSTER_NAME}.${base_domain}:22623/config/worker" "${cf_params_compute}"
  add_param_to_json CertificateAuthorities "$(echo ${IGNITION_CA} | sed 's/"//g')" "${cf_params_compute}"
  add_param_to_json WorkerInstanceType "${WORKER_INSTANCE_TYPE}" "${cf_params_compute}"
  add_param_to_json WorkerInstanceProfileName "${WORKER_INSTANCE_PROFILE}" "${cf_params_compute}"

  echo "${COMPUTE_STACK_NAME}" >> "${NEW_STACKS}"
  aws cloudformation create-stack \
    --stack-name "${COMPUTE_STACK_NAME}" \
    --template-body "$(cat "/var/lib/openshift-install/upi/aws/cloudformation/06_cluster_worker_node.yaml")" \
    --tags "${TAGS}" \
    --parameters file://${cf_params_compute} &
  wait "$!"

  aws cloudformation wait stack-create-complete --stack-name "${COMPUTE_STACK_NAME}" &
  wait "$!"
done

# --- Step 10: Wait for bootstrap complete ---
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Waiting for bootstrap to complete"
openshift-install --dir=${INSTALL_DIR} wait-for bootstrap-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!" || gather_bootstrap_and_fail

echo "Bootstrap complete, destroying bootstrap resources"
aws cloudformation delete-stack --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

aws cloudformation wait stack-delete-complete --stack-name "${BOOTSTRAP_STACK_NAME}" &
wait "$!"

sed -i "/^${BOOTSTRAP_STACK_NAME}$/d" "$NEW_STACKS"

# --- Step 11: Approve CSRs and wait for install complete ---
function approve_csrs() {
  oc version --client
  while true; do
    if [[ ! -f /tmp/install-complete ]]; then
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
      continue
    else
      break
    fi
  done
}

echo "Approving pending CSRs"
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig
approve_csrs &

set +x
echo "Completing UPI setup"
openshift-install --dir=${INSTALL_DIR} wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

touch /tmp/install-complete
