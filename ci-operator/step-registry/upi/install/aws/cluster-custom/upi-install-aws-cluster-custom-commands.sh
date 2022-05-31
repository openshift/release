#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=/tmp:${PATH}
oc version --client

GATHER_BOOTSTRAP_ARGS=

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

cp "$(command -v openshift-install)" /tmp
install_dir="/tmp/installer"
mkdir ${install_dir}

pushd ${install_dir}

which openshift-install
openshift-install version

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
# PULL_SECRET=${CLUSTER_PROFILE_DIR}/pull-secret

export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
export SSH_PRIV_KEY_PATH
export PULL_SECRET_PATH
export OPENSHIFT_INSTALL_INVOKER
export AWS_SHARED_CREDENTIALS_FILE
export EXPIRATION_DATE
# export PULL_SECRET

# install-config.yaml
cp ${SHARED_DIR}/install-config.yaml ${install_dir}/install-config.yaml

CLUSTER_NAME=$(yq-go r install-config.yaml 'metadata.name')
BASE_DOMAIN=$(yq-go r install-config.yaml 'baseDomain')
AWS_REGION=$(yq-go r install-config.yaml 'platform.aws.region')
PUBLISH_STRATEGY=$(yq-go r install-config.yaml 'publish') # External Internal
AWS_DEFAULT_REGION="${AWS_REGION}"  # CLI prefers the former
export AWS_DEFAULT_REGION

echo ${CLUSTER_NAME} > ${SHARED_DIR}/CLUSTER_NAME
echo ${AWS_REGION} > ${SHARED_DIR}/AWS_REGION
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"


function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
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

function aws_describe_stack() {
    local aws_region=$1
    local stack_name=$2
    local output_json="$3"
    cmd="aws --region ${aws_region} cloudformation describe-stacks --stack-name ${stack_name} > '${output_json}'"
    run_command "${cmd}" &
    wait "$!" || return 1
    return 0
}

function aws_create_stack() {
    local aws_region=$1
    local stack_name=$2
    local template_body="$3"
    local parameters="$4"
    local options="$5"
    local output_json="$6"

    cmd="aws --region ${aws_region} cloudformation create-stack --stack-name ${stack_name} ${options} --template-body '${template_body}' --parameters '${parameters}'"
    run_command "${cmd}" &
    wait "$!" || return 1

    cmd="aws --region ${aws_region} cloudformation wait stack-create-complete --stack-name ${stack_name}"
    run_command "${cmd}" &
    wait "$!" || return 1

    aws_describe_stack ${aws_region} ${stack_name} "$output_json" &
    wait "$!" || return 1

    return 0
}

function wait_and_approve() {
  set +e
  #Increase the retry to 25 due to sometimes machine-config-server getting up too late, 20 mins slow than machine-config-operator
  local role=$1 expected_nodes_num=$2 ready_nodes_num=0 try=0 retries=25 interval=60
  ready_nodes_num=$(oc get node --no-headers -l "node-role.kubernetes.io/${role}" | grep -wc Ready)
  while [ ${ready_nodes_num} -ne ${expected_nodes_num} ] && [ ${try} -lt ${retries} ]; do
    echo "Expected '${expected_nodes_num}' ${role} nodes to be Ready, but found '${ready_nodes_num}', waiting ${interval} sec....."
    sleep ${interval}
    (( try++ ))
    echo "Attempt #${try}, checking current status....."
    oc get node --no-headers -l "node-role.kubernetes.io/${role}" && oc get csr | grep Pending
    echo "Approving pending CSR requests (if any)....."
    oc get csr -o name | xargs -r oc adm certificate approve
    sleep 5 #allow a little time for the nodes to appear as Ready after approved
    ready_nodes_num=$(oc get node --no-headers -l "node-role.kubernetes.io/${role}" | grep -wc Ready)
  done
  if [ ${try} -eq ${retries} ]; then
    echo "ERROR: Timed out waiting for the '${role}' nodes to get Ready."
    return 1
  fi
  echo "All '${role}' nodes are Ready, continuing execution....."
  set -e
  return 0
}

function gather_bootstrap_and_fail() {
  if test -n "${GATHER_BOOTSTRAP_ARGS}"; then
    openshift-install --dir=${install_dir} gather bootstrap --key "${SSH_PRIV_KEY_PATH}" ${GATHER_BOOTSTRAP_ARGS}
  fi

  return 1
}


# Generate AWS UPI CF template

infra_cf_template="${ARTIFACT_DIR}/02_cluster_infra.yaml"
sg_cf_template="${ARTIFACT_DIR}/03_cluster_security.yaml"
bootstrap_cf_template="${ARTIFACT_DIR}/04_cluster_bootstrap.yaml"
master_cf_template="${ARTIFACT_DIR}/05_cluster_master_nodes.yaml"
worker_cf_template="${ARTIFACT_DIR}/06_cluster_worker_node.yaml"
apps_dns_cf_template="${ARTIFACT_DIR}/97_apps_ingress-elb_dns.yaml"


#
# template: ${infra_cf_template}
# 
echo "Creating ${infra_cf_template}"
cat > "${infra_cf_template}" <<EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs)

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
  HostedZoneId:
    Description: The Route53 public zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Type: String
  HostedZoneName:
    Description: The Route53 zone to register the targets with, such as example.com. Omit the trailing period.
    Type: String
    Default: "example.com"
  PublicSubnets:
    Description: The internet-facing subnets.
    Type: List<AWS::EC2::Subnet::Id>
  PrivateSubnets:
    Description: The internal subnets.
    Type: List<AWS::EC2::Subnet::Id>
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id
  RegisterExternalApiTargetGroup:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Register external elb or internal only.
    Type: String

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
      - PublicSubnets
      - PrivateSubnets
    - Label:
        default: "DNS"
      Parameters:
      - HostedZoneName
      - HostedZoneId
    ParameterLabels:
      ClusterName:
        default: "Cluster Name"
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      PublicSubnets:
        default: "Public Subnets"
      PrivateSubnets:
        default: "Private Subnets"
      HostedZoneName:
        default: "Public Hosted Zone Name"
      HostedZoneId:
        default: "Public Hosted Zone ID"

Conditions:
  IsGovCloud: !Equals ['aws-us-gov', !Ref "AWS::Partition"]
  DoExternal: !Equals ['yes', !Ref RegisterExternalApiTargetGroup]

Resources:
  ExtApiElb:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: !Join ["-", [!Ref InfrastructureName, "ext"]]
      IpAddressType: ipv4
      Subnets: !Ref PublicSubnets
      Type: network

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

  ExternalApiServerRecord:
    Condition: DoExternal
    Type: AWS::Route53::RecordSetGroup
    Properties:
      Comment: Alias record for the API server
      HostedZoneId: !Ref HostedZoneId
      RecordSets:
      - Name:
          !Join [
            ".",
            ["api", !Ref ClusterName, !Join ["", [!Ref HostedZoneName, "."]]],
          ]
        Type: A
        AliasTarget:
          HostedZoneId: !GetAtt ExtApiElb.CanonicalHostedZoneID
          DNSName: !GetAtt ExtApiElb.DNSName

  InternalApiServerRecord:
    Type: AWS::Route53::RecordSetGroup
    Properties:
      Comment: Alias record for the API server
      HostedZoneId: !Ref IntDns
      RecordSets:
        !If
          - "IsGovCloud"
          - - Name:
                !Join [
                  ".",
                  ["api", !Ref ClusterName, !Join ["", [!Ref HostedZoneName, "."]]],
                ]
              Type: CNAME
              TTL: 10
              ResourceRecords:
              - !GetAtt IntApiElb.DNSName
            - Name:
                !Join [
                  ".",
                  ["api-int", !Ref ClusterName, !Join ["", [!Ref HostedZoneName, "."]]],
                ]
              Type: CNAME
              TTL: 10
              ResourceRecords:
              - !GetAtt IntApiElb.DNSName
          - - Name:
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

  ExternalApiListener:
    Condition: DoExternal
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      DefaultActions:
      - Type: forward
        TargetGroupArn:
          Ref: ExternalApiTargetGroup
      LoadBalancerArn:
        Ref: ExtApiElb
      Port: 6443
      Protocol: TCP

  ExternalApiTargetGroup:
    Condition: DoExternal
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
          - !If
              - "DoExternal"
              - Effect: "Allow"
                Action:
                  [
                    "elasticloadbalancing:RegisterTargets",
                    "elasticloadbalancing:DeregisterTargets",
                  ]
                Resource: !Ref ExternalApiTargetGroup
              - !Ref "AWS::NoValue"

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
      Runtime: "python3.8"
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
            Resource: !Join [ '', [ 'arn:', !Ref "AWS::Partition", ':ec2:*:*:subnet/*'] ]
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
      Runtime: "python3.8"
      Timeout: 120

  RegisterPublicSubnetTags:
    Type: Custom::SubnetRegister
    Properties:
      ServiceToken: !GetAtt RegisterSubnetTags.Arn
      InfrastructureName: !Ref InfrastructureName
      Subnets: !Ref PublicSubnets

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
  ExternalApiLoadBalancerName:
    Description: Full name of the External API load balancer created.
    Value: !GetAtt ExtApiElb.LoadBalancerFullName
    Condition: DoExternal
  InternalApiLoadBalancerName:
    Description: Full name of the Internal API load balancer created.
    Value: !GetAtt IntApiElb.LoadBalancerFullName
  ApiServerDnsName:
    Description: Full hostname of the API server, which is required for the Ignition config files.
    Value: !Join [".", ["api-int", !Ref ClusterName, !Ref HostedZoneName]]
  RegisterNlbIpTargetsLambda:
    Description: Lambda ARN useful to help register or deregister IP targets for these load balancers.
    Value: !GetAtt RegisterNlbIpTargets.Arn
  ExternalApiTargetGroupArn:
    Description: ARN of External API target group.
    Value: !Ref ExternalApiTargetGroup
    Condition: DoExternal
  InternalApiTargetGroupArn:
    Description: ARN of Internal API target group.
    Value: !Ref InternalApiTargetGroup
  InternalServiceTargetGroupArn:
    Description: ARN of internal service target group.
    Value: !Ref InternalServiceTargetGroup
EOF

#
# template: ${sg_cf_template}
# 
echo "Creating ${sg_cf_template}"
cat > "${sg_cf_template}" <<EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Security Elements (Security Groups & IAM)

Parameters:
  InfrastructureName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Infrastructure name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, unique cluster ID used to tag cloud resources and identify items owned or used by the cluster.
    Type: String
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id
  PrivateSubnets:
    Description: The internal subnets.
    Type: List<AWS::EC2::Subnet::Id>

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - InfrastructureName
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcId
      - VpcCidr
      - PrivateSubnets
    ParameterLabels:
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      VpcCidr:
        default: "VPC CIDR"
      PrivateSubnets:
        default: "Private Subnets"

Resources:
  MasterSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Cluster Master Security Group
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: 0
        ToPort: 0
        CidrIp: !Ref VpcCidr
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: !Ref VpcCidr
      - IpProtocol: tcp
        ToPort: 6443
        FromPort: 6443
        CidrIp: !Ref VpcCidr
      - IpProtocol: tcp
        FromPort: 22623
        ToPort: 22623
        CidrIp: !Ref VpcCidr
      VpcId: !Ref VpcId
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "master", "sg"]]

  WorkerSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Cluster Worker Security Group
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: 0
        ToPort: 0
        CidrIp: !Ref VpcCidr
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: !Ref VpcCidr
      VpcId: !Ref VpcId
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "worker", "sg"]]

  MasterIngressEtcd:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: etcd
      FromPort: 2379
      ToPort: 2380
      IpProtocol: tcp

  MasterIngressVxlan:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Vxlan packets
      FromPort: 4789
      ToPort: 4789
      IpProtocol: udp

  MasterIngressWorkerVxlan:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Vxlan packets
      FromPort: 4789
      ToPort: 4789
      IpProtocol: udp

  MasterIngressGeneve:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Geneve packets
      FromPort: 6081
      ToPort: 6081
      IpProtocol: udp

  MasterIngressWorkerGeneve:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Geneve packets
      FromPort: 6081
      ToPort: 6081
      IpProtocol: udp

  MasterIngressIpsecIke:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: IPsec IKE packets
      FromPort: 500
      ToPort: 500
      IpProtocol: udp

  MasterIngressIpsecNat:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: IPsec NAT-T packets
      FromPort: 4500
      ToPort: 4500
      IpProtocol: udp

  MasterIngressIpsecEsp:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: IPsec ESP packets
      IpProtocol: 50

  MasterIngressWorkerIpsecIke:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: IPsec IKE packets
      FromPort: 500
      ToPort: 500
      IpProtocol: udp

  MasterIngressWorkerIpsecNat:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: IPsec NAT-T packets
      FromPort: 4500
      ToPort: 4500
      IpProtocol: udp

  MasterIngressWorkerIpsecEsp:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: IPsec ESP packets
      IpProtocol: 50

  MasterIngressInternal:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: tcp

  MasterIngressWorkerInternal:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: tcp

  MasterIngressInternalUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: udp

  MasterIngressWorkerInternalUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: udp

  MasterIngressKube:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Kubernetes kubelet, scheduler and controller manager
      FromPort: 10250
      ToPort: 10259
      IpProtocol: tcp

  MasterIngressWorkerKube:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Kubernetes kubelet, scheduler and controller manager
      FromPort: 10250
      ToPort: 10259
      IpProtocol: tcp

  MasterIngressIngressServices:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: tcp

  MasterIngressWorkerIngressServices:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: tcp

  MasterIngressIngressServicesUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: udp

  MasterIngressWorkerIngressServicesUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt MasterSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: udp

  WorkerIngressVxlan:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Vxlan packets
      FromPort: 4789
      ToPort: 4789
      IpProtocol: udp

  WorkerIngressMasterVxlan:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Vxlan packets
      FromPort: 4789
      ToPort: 4789
      IpProtocol: udp

  WorkerIngressGeneve:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Geneve packets
      FromPort: 6081
      ToPort: 6081
      IpProtocol: udp

  WorkerIngressMasterGeneve:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Geneve packets
      FromPort: 6081
      ToPort: 6081
      IpProtocol: udp

  WorkerIngressIpsecIke:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: IPsec IKE packets
      FromPort: 500
      ToPort: 500
      IpProtocol: udp

  WorkerIngressIpsecNat:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: IPsec NAT-T packets
      FromPort: 4500
      ToPort: 4500
      IpProtocol: udp

  WorkerIngressIpsecEsp:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: IPsec ESP packets
      IpProtocol: 50

  WorkerIngressMasterIpsecIke:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: IPsec IKE packets
      FromPort: 500
      ToPort: 500
      IpProtocol: udp

  WorkerIngressMasterIpsecNat:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: IPsec NAT-T packets
      FromPort: 4500
      ToPort: 4500
      IpProtocol: udp

  WorkerIngressMasterIpsecEsp:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: IPsec ESP packets
      IpProtocol: 50

  WorkerIngressInternal:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: tcp

  WorkerIngressMasterInternal:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: tcp

  WorkerIngressInternalUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: udp

  WorkerIngressMasterInternalUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Internal cluster communication
      FromPort: 9000
      ToPort: 9999
      IpProtocol: udp

  WorkerIngressKube:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Kubernetes secure kubelet port
      FromPort: 10250
      ToPort: 10250
      IpProtocol: tcp

  WorkerIngressWorkerKube:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Internal Kubernetes communication
      FromPort: 10250
      ToPort: 10250
      IpProtocol: tcp

  WorkerIngressIngressServices:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: tcp

  WorkerIngressMasterIngressServices:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: tcp

  WorkerIngressIngressServicesUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt WorkerSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: udp

  WorkerIngressMasterIngressServicesUDP:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !GetAtt WorkerSecurityGroup.GroupId
      SourceSecurityGroupId: !GetAtt MasterSecurityGroup.GroupId
      Description: Kubernetes ingress services
      FromPort: 30000
      ToPort: 32767
      IpProtocol: udp

  MasterIamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - !Join [ '', [ 'ec2.', !Ref "AWS::URLSuffix"] ]
          Action:
          - "sts:AssumeRole"
      Policies:
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "master", "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action:
            - "ec2:AttachVolume"
            - "ec2:AuthorizeSecurityGroupIngress"
            - "ec2:CreateSecurityGroup"
            - "ec2:CreateTags"
            - "ec2:CreateVolume"
            - "ec2:DeleteSecurityGroup"
            - "ec2:DeleteVolume"
            - "ec2:Describe*"
            - "ec2:DetachVolume"
            - "ec2:ModifyInstanceAttribute"
            - "ec2:ModifyVolume"
            - "ec2:RevokeSecurityGroupIngress"
            - "elasticloadbalancing:AddTags"
            - "elasticloadbalancing:AttachLoadBalancerToSubnets"
            - "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer"
            - "elasticloadbalancing:CreateListener"
            - "elasticloadbalancing:CreateLoadBalancer"
            - "elasticloadbalancing:CreateLoadBalancerPolicy"
            - "elasticloadbalancing:CreateLoadBalancerListeners"
            - "elasticloadbalancing:CreateTargetGroup"
            - "elasticloadbalancing:ConfigureHealthCheck"
            - "elasticloadbalancing:DeleteListener"
            - "elasticloadbalancing:DeleteLoadBalancer"
            - "elasticloadbalancing:DeleteLoadBalancerListeners"
            - "elasticloadbalancing:DeleteTargetGroup"
            - "elasticloadbalancing:DeregisterInstancesFromLoadBalancer"
            - "elasticloadbalancing:DeregisterTargets"
            - "elasticloadbalancing:Describe*"
            - "elasticloadbalancing:DetachLoadBalancerFromSubnets"
            - "elasticloadbalancing:ModifyListener"
            - "elasticloadbalancing:ModifyLoadBalancerAttributes"
            - "elasticloadbalancing:ModifyTargetGroup"
            - "elasticloadbalancing:ModifyTargetGroupAttributes"
            - "elasticloadbalancing:RegisterInstancesWithLoadBalancer"
            - "elasticloadbalancing:RegisterTargets"
            - "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer"
            - "elasticloadbalancing:SetLoadBalancerPoliciesOfListener"
            - "kms:DescribeKey"
            Resource: "*"

  MasterInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      InstanceProfileName: !Join ["-", [!Ref InfrastructureName, "master", "profile"]]
      Roles:
      - Ref: "MasterIamRole"

  WorkerIamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - !Join [ '', [ 'ec2.', !Ref "AWS::URLSuffix"] ]
          Action:
          - "sts:AssumeRole"
      Policies:
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "worker", "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action:
            - "ec2:DescribeInstances"
            - "ec2:DescribeRegions"
            Resource: "*"

  WorkerInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      InstanceProfileName: !Join ["-", [!Ref InfrastructureName, "worker", "profile"]]
      Roles:
      - Ref: "WorkerIamRole"

Outputs:
  MasterSecurityGroupId:
    Description: Master Security Group ID
    Value: !GetAtt MasterSecurityGroup.GroupId

  WorkerSecurityGroupId:
    Description: Worker Security Group ID
    Value: !GetAtt WorkerSecurityGroup.GroupId

  MasterInstanceProfile:
    Description: Master IAM Instance Profile
    Value: !Ref MasterInstanceProfile

  WorkerInstanceProfile:
    Description: Worker IAM Instance Profile
    Value: !Ref WorkerInstanceProfile
EOF

#
# template: ${bootstrap_cf_template}
# 
echo "Creating ${bootstrap_cf_template}"
cat > "${bootstrap_cf_template}" <<EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Bootstrap (EC2 Instance, Security Groups and IAM)

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
  BootstrapSubnet:
    Description: The public subnet to launch the bootstrap node into.
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
  FullBootstrapIgnitionBase64Data:
    Default: ""
    Description: Full ignition data with base 64 encoded.
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
  ExternalApiTargetGroupArn:
    Default: ""
    Description: ARN for external API load balancer target group.
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
  RegisterExternalApiTargetGroup:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Register external elb or internal only.
    Type: String
  AssignPublicIp:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Assign public ip to bootstrap node.
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - InfrastructureName
    - Label:
        default: "Host Information"
      Parameters:
      - BootstrapInstanceType
      - RhcosAmi
      - BootstrapIgnitionLocation
      - MasterSecurityGroupId
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcId
      - AllowedBootstrapSshCidr
      - BootstrapSubnet
    - Label:
        default: "Load Balancer Automation"
      Parameters:
      - AutoRegisterELB
      - RegisterNlbIpTargetsLambdaArn
      - ExternalApiTargetGroupArn
      - InternalApiTargetGroupArn
      - InternalServiceTargetGroupArn
    ParameterLabels:
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      AllowedBootstrapSshCidr:
        default: "Allowed SSH Source"
      BootstrapSubnet:
        default: "Public Subnet"
      BootstrapInstanceType:
        default: "Bootstrap Instance Type"
      RhcosAmi:
        default: "Red Hat Enterprise Linux CoreOS AMI ID"
      BootstrapIgnitionLocation:
        default: "Bootstrap Ignition Source"
      MasterSecurityGroupId:
        default: "Master Security Group ID"
      AutoRegisterELB:
        default: "Use Provided ELB Automation"

Conditions:
  DoPublicIp: !Equals ["yes", !Ref AssignPublicIp]
  DoRegistration: !Equals ["yes", !Ref AutoRegisterELB]
  DoExternal: !Equals ['yes', !Ref RegisterExternalApiTargetGroup]
  DoRegistrationAndExternal: !And
    - !Equals ["yes", !Ref AutoRegisterELB]
    - !Equals ['yes', !Ref RegisterExternalApiTargetGroup]
  UseFullBootstrapIgnitionBase64Data: !Not [ !Equals ['', !Ref FullBootstrapIgnitionBase64Data] ]

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
            - !Join [ '', [ 'ec2.', !Ref "AWS::URLSuffix"] ]
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
      - AssociatePublicIpAddress: !If ["DoPublicIp", "true", "false"]
        DeviceIndex: "0"
        GroupSet:
        - !Ref "BootstrapSecurityGroup"
        - !Ref "MasterSecurityGroupId"
        SubnetId: !Ref "BootstrapSubnet"
      UserData:
        !If
          - "UseFullBootstrapIgnitionBase64Data"
          - !Ref FullBootstrapIgnitionBase64Data
          - Fn::Base64: !Sub
            - '{"ignition":{"config":{"replace":{"source":"\${S3Loc}"}},"version":"3.1.0"}}'
            - {
                S3Loc: !Ref BootstrapIgnitionLocation
              }
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "bootstrap"]]

  RegisterBootstrapApiTarget:
    Condition: DoRegistrationAndExternal
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref ExternalApiTargetGroupArn
      TargetIp: !GetAtt BootstrapInstance.PrivateIp

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

  BootstrapPublicIp:
    Condition: DoPublicIp
    Description: The bootstrap node public IP address.
    Value: !GetAtt BootstrapInstance.PublicIp

  BootstrapPrivateIp:
    Description: The bootstrap node private IP address.
    Value: !GetAtt BootstrapInstance.PrivateIp
EOF

#
# template: ${master_cf_template}
# 
echo "Creating ${master_cf_template}"
cat > "${master_cf_template}" <<EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Node Launch (EC2 master instances)

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
  AutoRegisterDNS:
    Default: ""
    Description: unused
    Type: String
  PrivateHostedZoneId:
    Default: ""
    Description: unused
    Type: String
  PrivateHostedZoneName:
    Default: ""
    Description: unused
    Type: String
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
    Default: https://api-int.\$CLUSTER_NAME.\$DOMAIN:22623/config/master
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
    Default: m5.xlarge
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
  ExternalApiTargetGroupArn:
    Default: ""
    Description: ARN for external API load balancer target group. Supply the value from the cluster infrastructure or select "no" for AutoRegisterELB.
    Type: String
  InternalApiTargetGroupArn:
    Description: ARN for internal API load balancer target group. Supply the value from the cluster infrastructure or select "no" for AutoRegisterELB.
    Type: String
  InternalServiceTargetGroupArn:
    Description: ARN for internal service load balancer target group. Supply the value from the cluster infrastructure or select "no" for AutoRegisterELB.
    Type: String
  RegisterExternalApiTargetGroup:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Description: Register external elb or internal only.
    Type: String
  AdditionalDiskSizeDB:
    Description: Size of the Master VM 2nd data disk, in GB
    Type: String
    Default: ""

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - InfrastructureName
    - Label:
        default: "Host Information"
      Parameters:
      - MasterInstanceType
      - RhcosAmi
      - IgnitionLocation
      - CertificateAuthorities
      - MasterSecurityGroupId
      - MasterInstanceProfileName
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcId
      - AllowedBootstrapSshCidr
      - Master0Subnet
      - Master1Subnet
      - Master2Subnet
    - Label:
        default: "Load Balancer Automation"
      Parameters:
      - AutoRegisterELB
      - RegisterNlbIpTargetsLambdaArn
      - ExternalApiTargetGroupArn
      - InternalApiTargetGroupArn
      - InternalServiceTargetGroupArn
    ParameterLabels:
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      Master0Subnet:
        default: "Master-0 Subnet"
      Master1Subnet:
        default: "Master-1 Subnet"
      Master2Subnet:
        default: "Master-2 Subnet"
      MasterInstanceType:
        default: "Master Instance Type"
      MasterInstanceProfileName:
        default: "Master Instance Profile Name"
      RhcosAmi:
        default: "Red Hat Enterprise Linux CoreOS AMI ID"
      BootstrapIgnitionLocation:
        default: "Master Ignition Source"
      CertificateAuthorities:
        default: "Ignition CA String"
      MasterSecurityGroupId:
        default: "Master Security Group ID"
      AutoRegisterELB:
        default: "Use Provided ELB Automation"

Conditions:
  DoRegistration: !Equals ["yes", !Ref AutoRegisterELB]
  DoExternal: !Equals ['yes', !Ref RegisterExternalApiTargetGroup]
  DoRegistrationAndExternal: !And
    - !Equals ["yes", !Ref AutoRegisterELB]
    - !Equals ['yes', !Ref RegisterExternalApiTargetGroup]
  AdditionalDisk: !Not [ !Equals ['', !Ref AdditionalDiskSizeDB] ]

Resources:
  Master0:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      BlockDeviceMappings:
      - DeviceName: /dev/xvda
        Ebs:
          VolumeSize: "120"
          VolumeType: "gp2"
      - !If
          - "AdditionalDisk"
          - DeviceName: /dev/sdf
            Ebs:
              VolumeSize: !Ref AdditionalDiskSizeDB
              VolumeType: "gp2" 
          - !Ref "AWS::NoValue"
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
        - '{"ignition":{"config":{"merge":[{"source":"\${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"\${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "master", "0"]]
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

  RegisterMaster0:
    Condition: DoRegistrationAndExternal
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref ExternalApiTargetGroupArn
      TargetIp: !GetAtt Master0.PrivateIp

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
          VolumeType: "gp2"
      - !If
          - "AdditionalDisk"
          - DeviceName: /dev/sdf
            Ebs:
              VolumeSize: !Ref AdditionalDiskSizeDB
              VolumeType: "gp2" 
          - !Ref "AWS::NoValue"
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
        - '{"ignition":{"config":{"merge":[{"source":"\${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"\${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "master", "1"]]
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

  RegisterMaster1:
    Condition: DoRegistrationAndExternal
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref ExternalApiTargetGroupArn
      TargetIp: !GetAtt Master1.PrivateIp

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
          VolumeType: "gp2"
      - !If
          - "AdditionalDisk"
          - DeviceName: /dev/sdf
            Ebs:
              VolumeSize: !Ref AdditionalDiskSizeDB
              VolumeType: "gp2" 
          - !Ref "AWS::NoValue"
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
        - '{"ignition":{"config":{"merge":[{"source":"\${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"\${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "master", "2"]]
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

  RegisterMaster2:
    Condition: DoRegistrationAndExternal
    Type: Custom::NLBRegister
    Properties:
      ServiceToken: !Ref RegisterNlbIpTargetsLambdaArn
      TargetArn: !Ref ExternalApiTargetGroupArn
      TargetIp: !GetAtt Master2.PrivateIp

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
EOF

#
# template: ${worker_cf_template}
# 
echo "Creating ${worker_cf_template}"
cat > "${worker_cf_template}" <<EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Node Launch (EC2 worker instance)

Parameters:
  Index:
    Type: String
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
  Subnet:
    Description: The subnets, recommend private, to launch the master nodes into.
    Type: AWS::EC2::Subnet::Id
  WorkerSecurityGroupId:
    Description: The master security group ID to associate with master nodes.
    Type: AWS::EC2::SecurityGroup::Id
  IgnitionLocation:
    Default: https://api-int.\$CLUSTER_NAME.\$DOMAIN:22623/config/worker
    Description: Ignition config file location.
    Type: String
  CertificateAuthorities:
    Default: data:text/plain;charset=utf-8;base64,ABC...xYz==
    Description: Base64 encoded certificate authority string to use.
    Type: String
  WorkerInstanceProfileName:
    Description: IAM profile to associate with master nodes.
    Type: String
  WorkerInstanceType:
    Default: m5.large
    Type: String
  AdditionalDiskSizeDB:
    Description: Size of the Master VM 2nd data disk, in GB
    Type: String
    Default: ""

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - InfrastructureName
    - Label:
        default: "Host Information"
      Parameters:
      - WorkerInstanceType
      - RhcosAmi
      - IgnitionLocation
      - CertificateAuthorities
      - WorkerSecurityGroupId
      - WorkerInstanceProfileName
    - Label:
        default: "Network Configuration"
      Parameters:
      - Subnet
    ParameterLabels:
      Subnet:
        default: "Subnet"
      InfrastructureName:
        default: "Infrastructure Name"
      WorkerInstanceType:
        default: "Worker Instance Type"
      WorkerInstanceProfileName:
        default: "Worker Instance Profile Name"
      RhcosAmi:
        default: "Red Hat Enterprise Linux CoreOS AMI ID"
      IgnitionLocation:
        default: "Worker Ignition Source"
      CertificateAuthorities:
        default: "Ignition CA String"
      WorkerSecurityGroupId:
        default: "Worker Security Group ID"

Conditions:
  AdditionalDisk: !Not [ !Equals ['', !Ref AdditionalDiskSizeDB] ]

Resources:
  Worker0:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref RhcosAmi
      BlockDeviceMappings:
      - DeviceName: /dev/xvda
        Ebs:
          VolumeSize: "120"
          VolumeType: "gp2"
      - !If
          - "AdditionalDisk"
          - DeviceName: /dev/sdf
            Ebs:
              VolumeSize: !Ref AdditionalDiskSizeDB
              VolumeType: "gp2" 
          - !Ref "AWS::NoValue"
      IamInstanceProfile: !Ref WorkerInstanceProfileName
      InstanceType: !Ref WorkerInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "false"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "WorkerSecurityGroupId"
        SubnetId: !Ref "Subnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"merge":[{"source":"\${SOURCE}"}]},"security":{"tls":{"certificateAuthorities":[{"source":"\${CA_BUNDLE}"}]}},"version":"3.1.0"}}'
        - {
          SOURCE: !Ref IgnitionLocation,
          CA_BUNDLE: !Ref CertificateAuthorities,
        }
      Tags:
      - Key: "Name"
        Value: !Join ["-", [!Ref InfrastructureName, "node", !Ref Index]]
      - Key: !Join ["", ["kubernetes.io/cluster/", !Ref InfrastructureName]]
        Value: "shared"

Outputs:
  PrivateIP:
    Description: The compute node private IP address.
    Value: !GetAtt Worker0.PrivateIp
EOF

#
# template: ${apps_dns_cf_template}
# 
echo "Creating ${apps_dns_cf_template}"
cat > "${apps_dns_cf_template}" <<EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Network Elements (Route53 & LBs)

Parameters:
  PublicHostedZoneId:
    Description: The Route53 public zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Default: ""
    Type: String
  PrivateHostedZoneId:
    Description: The Route53 private zone ID to register the targets with, such as Z21IXYZABCZ2A4.
    Type: String
  PrivateHostedZoneName:
    Description: The Route53 zone to register the targets with, such as cluster.example.com. Omit the trailing period.
    Type: String
  RouterLbDns:
    Description: The loadbalancer DNS
    Type: String
  RouterLbHostedZoneId:
    Description: The Route53 zone ID where loadbalancer reside
    Default: ""
    Type: String
  RegisterPublicAppsDNS:
    Default: "yes"
    AllowedValues:
    - "yes"
    - "no"
    Type: String


Conditions:
  IsGovCloud: !Equals ['aws-us-gov', !Ref "AWS::Partition"]
  DoRegistration: !Equals ["yes", !Ref RegisterPublicAppsDNS]


Metadata:
  AWS::CloudFormation::Interface:
    ParameterLabels:
      PublicHostedZoneId:
        default: "Public Hosted Zone ID"
      PrivateHostedZoneId:
        default: "Private Hosted Zone ID"
      PrivateHostedZoneName:
        default: "Private Hosted Zone Name"
      RouterLbDns:
        default: "router loadbalancer dns"
      RouterLbHostedZoneId:
        default: "Private Hosted Zone ID of router lb"


Resources:
  ExternalAppsRecord:
    Condition: DoRegistration
    Type: AWS::Route53::RecordSet
    Properties:
      AliasTarget:
        DNSName: !Ref RouterLbDns
        HostedZoneId: !Ref RouterLbHostedZoneId
        EvaluateTargetHealth: false
      HostedZoneId: !Ref PublicHostedZoneId
      Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
      Type: A

  InternalAppsRecord:
    Type: AWS::Route53::RecordSet
    Properties:
      !If
        - "IsGovCloud"
        - HostedZoneId: !Ref PrivateHostedZoneId
          Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
          Type: CNAME
          TTL: 10
          ResourceRecords:
          - !Ref RouterLbDns
        - HostedZoneId: !Ref PrivateHostedZoneId
          Name: !Join [".", ["*.apps", !Ref PrivateHostedZoneName]]
          AliasTarget:
            DNSName: !Ref RouterLbDns
            HostedZoneId: !Ref RouterLbHostedZoneId
            EvaluateTargetHealth: false
          Type: A
EOF

# Note:
# stack name has been hardcoded in destroy script: compute-2 compute-1 compute-0 control-plane bootstrap proxy security infra vpc
# ------------------------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------------------------

VPC_ID=$(head -n 1 "${SHARED_DIR}/vpc_id")
PRIVATE_SUBNETS_COMMA=$(yq-go r --tojson "${SHARED_DIR}/private_subnet_ids" | jq -r '. | join(",")')
PRIVATE_SUBNET_0=$(yq-go r "${SHARED_DIR}/private_subnet_ids" [0])
PRIVATE_SUBNET_1=$(yq-go r "${SHARED_DIR}/private_subnet_ids" [1])
PRIVATE_SUBNET_2=$(yq-go r "${SHARED_DIR}/private_subnet_ids" [2])
if [[ "${PRIVATE_SUBNET_2}" == "" ]]; then
  PRIVATE_SUBNET_2=$PRIVATE_SUBNET_1
fi
if [[ "${PRIVATE_SUBNET_1}" == "" ]]; then
  PRIVATE_SUBNET_1=$PRIVATE_SUBNET_0
  PRIVATE_SUBNET_2=$PRIVATE_SUBNET_0
fi

PUBLIC_SUBNETS_COMMA=$(yq-go r --tojson "${SHARED_DIR}/public_subnet_ids" | jq -r '. | join(",")')
PUBLIC_SUBNET_0=$(yq-go r "${SHARED_DIR}/public_subnet_ids" [0])


# ------------------------------------------------------------------------------------
# Proxy
# ------------------------------------------------------------------------------------

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi


# ------------------------------------------------------------------------------------
# RHCOS
# ------------------------------------------------------------------------------------

ARCH="x86_64"
if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
  ARCH="aarch64"
fi
cmd="openshift-install coreos print-stream-json | jq -r '.architectures.${ARCH}.images.aws.regions.\"$AWS_REGION\".image'"
RHCOS_AMI=$(eval "$cmd")
RHCOS_AMI_MASTER=$RHCOS_AMI
RHCOS_AMI_WORKER=$RHCOS_AMI

# ------------------------------------------------------------------------------------
# Create ignition configs
# ------------------------------------------------------------------------------------

openshift-install --dir=${install_dir} create manifests &
wait "$!"

# CVO
# yq-go d -i ${install_dir}/manifests/cvo-overrides.yaml spec.channel

# remove machine set
rm -f ${install_dir}/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f ${install_dir}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

# ensure mastersSchedulable is false
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" ${install_dir}/manifests/cluster-scheduler-02-config.yml

echo "Will include manifests:"
find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${install_dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)

find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

mkdir -p "${install_dir}/tls"
while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${install_dir}/tls/${manifest##tls_}"
done <   <( find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)


# remove DNS config
if [[ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]]; then
  echo "Removing cluster dns config from manifest assets....."
  yq-go d -i ${install_dir}/manifests/cluster-dns-02-config.yml spec.privateZone
  if [[ "${PUBLISH_STRATEGY}" == "External" ]]; then
    yq-go d -i ${install_dir}/manifests/cluster-dns-02-config.yml spec.publicZone
  fi
fi

echo "Creating ignition configs"
openshift-install --dir=${install_dir} create ignition-configs

INFRA_ID="$(jq -r .infraID ${install_dir}/metadata.json)"
ROUTE53_HOSTZONE_NAME="${BASE_DOMAIN}."
ROUTE53_HOSTZONE_ID=$(aws --region ${AWS_REGION} route53 list-hosted-zones \
                      --query 'HostedZones[? !(Config.PrivateZone)]' \
                      | jq --arg route53_hostzone_name "$ROUTE53_HOSTZONE_NAME" \
                      '.[] | select(.Name==$route53_hostzone_name) | .Id' | tr -d '"' | awk -F'/' '{print $NF}')

echo "Copying ignition to s3"
timestamp=$(date +%y%m%d%H%M%S)
remote_s3="s3://${CLUSTER_NAME}-${timestamp}"
remote_bootstrap_ignition_file="${remote_s3}/bootstrap_${timestamp}.ign"
if aws --region ${AWS_REGION} s3 ls "${remote_s3}" >/dev/null 2>&1; then
  :
else
  aws --region ${AWS_REGION} s3 mb "${remote_s3}"
  echo "${remote_s3}" >> "${SHARED_DIR}/to_be_removed_s3_bucket_list"
fi
aws --region ${AWS_REGION} s3 cp "${install_dir}/bootstrap.ign" ${remote_bootstrap_ignition_file}

# ------------------------------------------------------------------------------------
# Infra
# ------------------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Cluster Type                  |   Private IP  |   ExternalApiTargetGroupArn
# -----------------------------------------------------------------------------
# common cluster                |   no          |   yes
# private cluster               |   yes         |   no
# private&disconnected cluster  |   yes         |   no
# -----------------------------------------------------------------------------

REGISTER_EXTERNAL_API_TARGET_GROUP="yes"
BOOTSTRAP_SUBNET=${PUBLIC_SUBNET_0}
ASSIGN_BOOTSTRAP_PUBLIC_IP="yes"
if [[ "${PUBLISH_STRATEGY}" == "Internal" ]]; then
    REGISTER_EXTERNAL_API_TARGET_GROUP="no"
    BOOTSTRAP_SUBNET=${PRIVATE_SUBNET_0}
    ASSIGN_BOOTSTRAP_PUBLIC_IP="no"
fi

echo "Creating DNS entries and Load Balancers"

infra_stack_name="${CLUSTER_NAME}-infra"
infra_params="${ARTIFACT_DIR}/aws_stack_infra_params.json"
infra_output="${ARTIFACT_DIR}/aws_stack_infra_output.json"

aws_add_param_to_json "ClusterName" "${CLUSTER_NAME}" "$infra_params"
aws_add_param_to_json "InfrastructureName" "${INFRA_ID}" "$infra_params"
aws_add_param_to_json "HostedZoneId" "${ROUTE53_HOSTZONE_ID}" "$infra_params"
aws_add_param_to_json "HostedZoneName" "${BASE_DOMAIN}" "$infra_params"
aws_add_param_to_json "PublicSubnets" "${PUBLIC_SUBNETS_COMMA}" "$infra_params"
aws_add_param_to_json "PrivateSubnets" "${PRIVATE_SUBNETS_COMMA}" "$infra_params"
aws_add_param_to_json "VpcId" "${VPC_ID}" "$infra_params"
aws_add_param_to_json "RegisterExternalApiTargetGroup" "${REGISTER_EXTERNAL_API_TARGET_GROUP}" "$infra_params"

extra_options=" --capabilities CAPABILITY_NAMED_IAM --tags \"${TAGS}\" "

cat "$infra_params"
aws_create_stack ${AWS_REGION} ${infra_stack_name} \
    "file://${infra_cf_template}" \
    "file://${infra_params}" \
    "${extra_options}" \
    "${infra_output}"


EXTERNAL_API_TARGET_GROUP_ARN=$(cat "${infra_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="ExternalApiTargetGroupArn") | .OutputValue')
INTERNAL_API_TARGET_GROUP_ARN=$(cat "${infra_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InternalApiTargetGroupArn") | .OutputValue')
API_SERVER_DNS_NAME=$(cat "${infra_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="ApiServerDnsName") | .OutputValue')
# PRIVATE_HOSTED_ZONE_ID=$(cat "${infra_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateHostedZoneId") | .OutputValue')
REGISTER_NLB_IP_TARGETS_LAMBDA=$(cat "${infra_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="RegisterNlbIpTargetsLambda") | .OutputValue')
INTERNAL_SERVICE_TARGET_GROUP_ARN=$(cat "${infra_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="InternalServiceTargetGroupArn") | .OutputValue')

# ------------------------------------------------------------------------------------
# Security Groups and IAM
# ------------------------------------------------------------------------------------

echo "Create Security Groups and IAM Roles......."
sg_iam_stack_name="${CLUSTER_NAME}-security"

sec_params="${ARTIFACT_DIR}/aws_stack_sec_params.json"
sec_output="${ARTIFACT_DIR}/aws_stack_sec_output.json"

aws_add_param_to_json "InfrastructureName" "${INFRA_ID}" "$sec_params"
aws_add_param_to_json "VpcId" "${VPC_ID}" "$sec_params"
aws_add_param_to_json "PrivateSubnets" "${PRIVATE_SUBNETS_COMMA}" "$sec_params"
extra_options=" --capabilities CAPABILITY_NAMED_IAM --tags \"${TAGS}\" "

cat "$sec_params"
aws_create_stack ${AWS_REGION} ${sg_iam_stack_name} \
    "file://${sg_cf_template}" \
    "file://${sec_params}" \
    "${extra_options}" \
    "${sec_output}"

MASTER_SECURITY_GROUP_ID=$(cat "${sec_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="MasterSecurityGroupId") | .OutputValue')
MASTER_INSTANCE_PROFILE=$(cat "${sec_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="MasterInstanceProfile") | .OutputValue')
WORKER_SECURITY_GROUP_ID=$(cat "${sec_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="WorkerSecurityGroupId") | .OutputValue')
WORKER_INSTANCE_PROFILE=$(cat "${sec_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="WorkerInstanceProfile") | .OutputValue')


# ------------------------------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------------------------------


echo "Creating bootstrap node and temporary security group plus IAM configuration"

bootstrap_stack_name="${CLUSTER_NAME}-bootstrap"
bootstrap_params="${ARTIFACT_DIR}/aws_stack_bootstrap_params.json"
bootstrap_output="${ARTIFACT_DIR}/aws_stack_bootstrap_output.json"
aws_add_param_to_json "InfrastructureName" "${INFRA_ID}" "$bootstrap_params"
aws_add_param_to_json "RhcosAmi" "${RHCOS_AMI_MASTER}" "$bootstrap_params"
aws_add_param_to_json "MasterSecurityGroupId" "${MASTER_SECURITY_GROUP_ID}" "$bootstrap_params"
aws_add_param_to_json "VpcId" "${VPC_ID}" "$bootstrap_params"
aws_add_param_to_json "BootstrapIgnitionLocation" "${remote_bootstrap_ignition_file}" "$bootstrap_params"
aws_add_param_to_json "RegisterNlbIpTargetsLambdaArn" "${REGISTER_NLB_IP_TARGETS_LAMBDA}" "$bootstrap_params"
aws_add_param_to_json "InternalApiTargetGroupArn" "${INTERNAL_API_TARGET_GROUP_ARN}" "$bootstrap_params"
aws_add_param_to_json "InternalServiceTargetGroupArn" "${INTERNAL_SERVICE_TARGET_GROUP_ARN}" "$bootstrap_params"
aws_add_param_to_json "BootstrapInstanceType" "${BOOTSTRAP_INSTANCE_TYPE}" "$bootstrap_params"
aws_add_param_to_json "RegisterExternalApiTargetGroup" "${REGISTER_EXTERNAL_API_TARGET_GROUP}" "$bootstrap_params"
aws_add_param_to_json "BootstrapSubnet" "${BOOTSTRAP_SUBNET}" "$bootstrap_params"
aws_add_param_to_json "AssignPublicIp" "${ASSIGN_BOOTSTRAP_PUBLIC_IP}" "$bootstrap_params"
if [[ "${REGISTER_EXTERNAL_API_TARGET_GROUP}" == "yes" ]]; then
    aws_add_param_to_json "ExternalApiTargetGroupArn" "${EXTERNAL_API_TARGET_GROUP_ARN}" "$bootstrap_params"
fi
extra_options=" --capabilities CAPABILITY_NAMED_IAM --tags \"${TAGS}\" "

cat "$bootstrap_params"
aws_create_stack ${AWS_REGION} ${bootstrap_stack_name} \
    "file://${bootstrap_cf_template}" \
    "file://${bootstrap_params}" \
    "${extra_options}" \
    "${bootstrap_output}"

BOOTSTRAP_PUBLIC_IP=$(cat "${bootstrap_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="BootstrapPublicIp") | .OutputValue')
BOOTSTRAP_PRIVATE_IP=$(cat "${bootstrap_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="BootstrapPrivateIp") | .OutputValue')

if [[ "${ASSIGN_BOOTSTRAP_PUBLIC_IP}" == "yes" ]]; then
  BOOTSTRAP_IP=${BOOTSTRAP_PUBLIC_IP}
else
  BOOTSTRAP_IP=${BOOTSTRAP_PRIVATE_IP}
fi


GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --bootstrap ${BOOTSTRAP_IP}"

# ------------------------------------------------------------------------------------
# Control Plane
# ------------------------------------------------------------------------------------

echo "Creating master and DNS entries for etcd......."
master_stack_name="${CLUSTER_NAME}-control-plane"

master_cert_content=$(cat "${install_dir}/master.ign" | jq -r '.ignition.security.tls.certificateAuthorities[].source')

master_params="${ARTIFACT_DIR}/aws_stack_master_params.json"
master_output="${ARTIFACT_DIR}/aws_stack_master_output.json"

aws_add_param_to_json "InfrastructureName" "${INFRA_ID}" "$master_params"
aws_add_param_to_json "RhcosAmi" "${RHCOS_AMI_MASTER}" "$master_params"
aws_add_param_to_json "MasterSecurityGroupId" "${MASTER_SECURITY_GROUP_ID}" "$master_params"
aws_add_param_to_json "IgnitionLocation" "https://${API_SERVER_DNS_NAME}:22623/config/master" "$master_params"
aws_add_param_to_json "Master0Subnet" "${PRIVATE_SUBNET_0}" "$master_params"
aws_add_param_to_json "Master1Subnet" "${PRIVATE_SUBNET_1}" "$master_params"
aws_add_param_to_json "Master2Subnet" "${PRIVATE_SUBNET_2}" "$master_params"
aws_add_param_to_json "CertificateAuthorities" "${master_cert_content}" "$master_params"
aws_add_param_to_json "MasterSecurityGroupId" "${MASTER_SECURITY_GROUP_ID}" "$master_params"
aws_add_param_to_json "MasterInstanceProfileName" "${MASTER_INSTANCE_PROFILE}" "$master_params"
aws_add_param_to_json "RegisterNlbIpTargetsLambdaArn" "${REGISTER_NLB_IP_TARGETS_LAMBDA}" "$master_params"
aws_add_param_to_json "InternalApiTargetGroupArn" "${INTERNAL_API_TARGET_GROUP_ARN}" "$master_params"
aws_add_param_to_json "InternalServiceTargetGroupArn" "${INTERNAL_SERVICE_TARGET_GROUP_ARN}" "$master_params"
aws_add_param_to_json "MasterInstanceType" "${MASTER_INSTANCE_TYPE}" "$master_params"

aws_add_param_to_json "RegisterExternalApiTargetGroup" "${REGISTER_EXTERNAL_API_TARGET_GROUP}" "$master_params"
if [[ "${REGISTER_EXTERNAL_API_TARGET_GROUP}" == "yes" ]]; then
    aws_add_param_to_json "ExternalApiTargetGroupArn" "${EXTERNAL_API_TARGET_GROUP_ARN}" "$master_params"
fi

extra_options=" --capabilities CAPABILITY_NAMED_IAM --tags \"${TAGS}\" "

cat "$master_params"
aws_create_stack ${AWS_REGION} ${master_stack_name} \
    "file://${master_cf_template}" \
    "file://${master_params}" \
    "${extra_options}" \
    "${master_output}"

CONTROL_PLANE_IPS=$(cat "${master_output}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateIPs") | .OutputValue')
CONTROL_PLANE_0_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f1)"
CONTROL_PLANE_1_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f2)"
CONTROL_PLANE_2_IP="$(echo "${CONTROL_PLANE_IPS}" | cut -d, -f3)"
GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master ${CONTROL_PLANE_0_IP} --master ${CONTROL_PLANE_1_IP} --master ${CONTROL_PLANE_2_IP}"


# ------------------------------------------------------------------------------------
# wait-for bootstrap-complete
# ------------------------------------------------------------------------------------
echo "Waiting for bootstrap to complete"
openshift-install --dir=${install_dir} wait-for bootstrap-complete &
wait "$!" || gather_bootstrap_and_fail

echo "Bootstrap complete, destroying bootstrap resources"
aws cloudformation delete-stack --stack-name "${bootstrap_stack_name}" &
wait "$!"

aws cloudformation wait stack-delete-complete --stack-name "${bootstrap_stack_name}" &
wait "$!"


# ------------------------------------------------------------------------------------
# Compute nodes
# ------------------------------------------------------------------------------------

declare -a COMPUTE_IPS
for index in 0 1 2; do
    echo "Launch Additional Worker Node ${index}....."
    worker_stack_name="${CLUSTER_NAME}-compute-${index}"
    worker_cert_content=$(cat "${install_dir}/worker.ign" | jq -r '.ignition.security.tls.certificateAuthorities[].source')

    worker_params="${ARTIFACT_DIR}/aws_stack_worker_${index}_params.json"
    worker_output="${ARTIFACT_DIR}/aws_stack_worker_${index}_output.json"

    SUBNET="PRIVATE_SUBNET_${index}"

    aws_add_param_to_json "Index" "${index}" "$worker_params"
    aws_add_param_to_json "InfrastructureName" "${INFRA_ID}" "$worker_params"
    aws_add_param_to_json "IgnitionLocation" "https://${API_SERVER_DNS_NAME}:22623/config/worker" "$worker_params"
    aws_add_param_to_json "Subnet" "${!SUBNET}" "$worker_params"
    aws_add_param_to_json "CertificateAuthorities" "${worker_cert_content}" "$worker_params"
    aws_add_param_to_json "WorkerSecurityGroupId" "${WORKER_SECURITY_GROUP_ID}" "$worker_params"
    aws_add_param_to_json "WorkerInstanceProfileName" "${WORKER_INSTANCE_PROFILE}" "$worker_params"
    aws_add_param_to_json "RhcosAmi" "${RHCOS_AMI_WORKER}" "$worker_params"
    aws_add_param_to_json "WorkerInstanceType" "${WORKER_INSTANCE_TYPE}" "$worker_params"
    extra_options=" --capabilities CAPABILITY_NAMED_IAM --tags \"${TAGS}\" "

    cat "$worker_params"
    aws_create_stack ${AWS_REGION} ${worker_stack_name} \
        "file://${worker_cf_template}" \
        "file://${worker_params}" \
        "${extra_options}" \
        "${worker_output}"

    COMPUTE_IP=$(cat ${worker_output} | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateIP") | .OutputValue')
    COMPUTE_IPS+=("$COMPUTE_IP")
done


echo "bootstrap: ${BOOTSTRAP_IP} control-plane: ${CONTROL_PLANE_0_IP} ${CONTROL_PLANE_1_IP} ${CONTROL_PLANE_2_IP} compute: ${COMPUTE_IPS[0]} ${COMPUTE_IPS[1]} ${COMPUTE_IPS[2]}"

# ------------------------------------------------------------------------------------
# Approve CSRs
# ------------------------------------------------------------------------------------

export KUBECONFIG="${install_dir}/auth/kubeconfig"


#Actaully if bootkube is still running, all nodes's csr would be signed automatically, but once bootkube is done, would not approve any csr
#Check `approve-csr` service on bootstrap - /usr/local/bin/approve-csr.sh
#So have to run some wait and approve here
wait_and_approve "master" "3"
wait_and_approve "worker" "3"

# ------------------------------------------------------------------------------------
# Add ingress manually
# ------------------------------------------------------------------------------------

if [ "${ADD_INGRESS_RECORDS_MANUALLY}" == "yes" ]; then

  apps_dns_stack_name="${CLUSTER_NAME}-apps-dns"
  apps_dns_params="${ARTIFACT_DIR}/aws_stack_apps_dns_params.json"
  apps_dns_output="${ARTIFACT_DIR}/aws_stack_apps_dns_output.json"
  
  PRIVATE_ROUTE53_HOSTZONE_NAME="${CLUSTER_NAME}.${BASE_DOMAIN}"
  PRIVATE_ROUTE53_HOSTZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${PRIVATE_ROUTE53_HOSTZONE_NAME}" --max-items 1 | jq -r '.HostedZones[].Id' | awk -F '/' '{print $3}')
  ROUTER_LB=$(oc -n openshift-ingress get service router-default -o json | jq -r '.status.loadBalancer.ingress[].hostname')
  
  aws_add_param_to_json "PrivateHostedZoneId" "${PRIVATE_ROUTE53_HOSTZONE_ID}" "$apps_dns_params"
  aws_add_param_to_json "PrivateHostedZoneName" "${PRIVATE_ROUTE53_HOSTZONE_NAME}" "$apps_dns_params"
  aws_add_param_to_json "RouterLbDns" "${ROUTER_LB}" "$apps_dns_params"

  if [[ "${PUBLISH_STRATEGY}" == "Internal" ]]; then
    aws_add_param_to_json "RegisterPublicAppsDNS" "no" "$apps_dns_params"
  fi

  if [[ "${CLUSTER_TYPE}" == "aws" ]] || [[ "${CLUSTER_TYPE}" == "aws-arm64" ]]; then
    ROUTER_LB_HOSTZONE_ID=$(aws --region ${AWS_REGION} elb describe-load-balancers | jq -r ".LoadBalancerDescriptions[] | select(.DNSName == \"${ROUTER_LB}\").CanonicalHostedZoneNameID")
    aws_add_param_to_json "RouterLbHostedZoneId" "${ROUTER_LB_HOSTZONE_ID}" "$apps_dns_params"
  fi

  extra_options=" --capabilities CAPABILITY_NAMED_IAM --tags \"${TAGS}\" "
  cat "$apps_dns_params"

  aws_create_stack ${AWS_REGION} ${apps_dns_stack_name} \
      "file://${apps_dns_cf_template}" \
      "file://${apps_dns_params}" \
      "${extra_options}" \
      "${apps_dns_output}"

fi

# ------------------------------------------------------------------------------------
# Complete UPI installation
# ------------------------------------------------------------------------------------

echo "Completing UPI setup"
openshift-install --dir=${install_dir} wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' ${install_dir}/.openshift_install.log
# The image registry in some instances the config object
# is not properly configured. Rerun patching
# after cluster complete
cp "${install_dir}/metadata.json" "${SHARED_DIR}/"
cp "${install_dir}/auth/kubeconfig" "${SHARED_DIR}"
touch /tmp/install-complete
