#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

# Get the VPC ID
vpc_id=$(head -n 1 ${SHARED_DIR}/vpc_id)
if [[ -z $vpc_id ]]; then
  echo "Error: Can not get VPC id, exit"
  echo "vpc: $vpc_id"
  exit 1
fi

# Domain list
OCP_DOMAIN_ALLOW_LIST=$(echo -e '
  registry.redhat.io,
  access.redhat.com,
  quay.io,
  *.quay.io,
  *.openshiftapps.com,
  sso.redhat.com,
  cert-api.access.redhat.com,
  api.access.redhat.com,
  infogw.api.openshift.com,
  console.redhat.com,
  ec2.amazonaws.com,
  events.amazonaws.com,
  iam.amazonaws.com,
  route53.amazonaws.com,
  s3.amazonaws.com,
  s3.'${REGION}'.amazonaws.com,
  s3.dualstack.'${REGION}'.amazonaws.com,
  sts.amazonaws.com,
  sts.'${REGION}'.amazonaws.com,
  ec2.'${REGION}'.amazonaws.com,
  elasticloadbalancing.'${REGION}'.amazonaws.com,
  servicequotas.'${REGION}'.amazonaws.com,
  tagging.'${REGION}'.amazonaws.com,
  mirror.openshift.com,
  storage.googleapis.com,
  quayio-production-s3.s3.amazonaws.com,
  api.openshift.com,
  rhcos.mirror.openshift.com
')

OSD_DOMAIN_ALLOW_LIST=$(echo -e '
  registry.redhat.io,
  quay.io,
  *.quay.io,
  *.openshiftapps.com,
  sso.redhat.com,
  quay-registry.s3.amazonaws.com,
  ocm-quay-production-s3.s3.amazonaws.com,
  quayio-production-s3.s3.amazonaws.com,
  cart-rhcos-ci.s3.amazonaws.com,
  openshift.org,
  registry.access.redhat.com,
  registry.connect.redhat.com,
  pull.q1w2.quay.rhcloud.com,
  *.q1w2.quay.rhcloud.com,
  www.okd.io,
  www.redhat.com,
  aws.amazon.com,
  catalog.redhat.com,
  cert-api.access.redhat.com,
  api.access.redhat.com,
  infogw.api.openshift.com,
  console.redhat.com,
  cloud.redhat.com,
  observatorium-mst.api.openshift.com,
  observatorium.api.openshift.com,
  ec2.amazonaws.com,
  events.'${REGION}'.amazonaws.com,
  iam.amazonaws.com,
  route53.amazonaws.com,
  sts.amazonaws.com,
  sts.'${REGION}'.amazonaws.com,
  ec2.'${REGION}'.amazonaws.com,
  elasticloadbalancing.'${REGION}'.amazonaws.com,
  servicequotas.'${REGION}'.amazonaws.com,
  tagging.'${REGION}'.amazonaws.com,
  mirror.openshift.com,
  storage.googleapis.com,
  api.openshift.com,
  api.pagerduty.com,
  events.pagerduty.com,
  api.deadmanssnitch.com,
  nosnch.in,
  *.osdsecuritylogs.splunkcloud.com,
  http-inputs-osdsecuritylogs.splunkcloud.com,
  sftp.access.redhat.com,
  *.openshift.io,
  *.openshift.org
')

DOMAIN_LIST=${OCP_DOMAIN_ALLOW_LIST}
if [[ ${ENABLE_MANAGED_FIREWALL} == "yes" ]]; then
  DOMAIN_LIST=${OSD_DOMAIN_ALLOW_LIST}
fi
if [[ "$REGION" != "us-east-1" ]]; then
  DOMAIN_LIST="$DOMAIN_LIST, tagging.us-east-1.amazonaws.com"
fi
DOMAIN_LIST=$(echo $DOMAIN_LIST)

function aws_add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

# Create DNS firewall
cat > /tmp/01_dns_firewall.yaml << EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Template for AWS DNS firewall'
Parameters:
  VpcId:
    Description: VPC id that to be assosiated with DNS firewall rule group.
    Type: String
  FirewallRuleGroupName:
    Description: The name that is using for the DNS firewall rule group.
    Type: String
  DomainList:
    Description: The comma-delimited list of the domains.
    Type: CommaDelimitedList
Resources:
  AllowedFirewallDomainList:
    Type: 'AWS::Route53Resolver::FirewallDomainList'
    Properties:
      Name: !Join ["-", [ !Ref "AWS::StackName", "fw-allowed-list" ] ]
      Domains: !Ref DomainList
  BlockedFirewallDomainList:
    Type: 'AWS::Route53Resolver::FirewallDomainList'
    Properties:
      Name: !Join ["-", [ !Ref "AWS::StackName", "fw-blocked-list" ] ]
      Domains:
      - "*"
  ResolverFirewallRuleGroup:
    Type: 'AWS::Route53Resolver::FirewallRuleGroup'
    Properties:
      Name: !Ref FirewallRuleGroupName
      FirewallRules:
        - Priority: 101
          Action: ALLOW
          FirewallDomainListId:
            Ref: AllowedFirewallDomainList
        - Priority: 102
          Action: BLOCK
          BlockResponse: NODATA
          FirewallDomainListId:
            Ref: BlockedFirewallDomainList
  FirewallRuleGroupAssociation:
    Type: AWS::Route53Resolver::FirewallRuleGroupAssociation
    DependsOn: ResolverFirewallRuleGroup
    Properties:
      FirewallRuleGroupId: !Ref ResolverFirewallRuleGroup
      MutationProtection: DISABLED
      Priority: 101
      VpcId: !Ref VpcId
Metadata: {}
Conditions: {}
Outputs:
  FirewallRuleGroupId:
    Description: ID of the DNS firewall rule group.
    Value: !Ref ResolverFirewallRuleGroup
  FirewallRuleGroupAssociationId:
    Description: ID of the DNS firewall Rule Group association.
    Value: !Ref FirewallRuleGroupAssociation
EOF

STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-dns-firewall"
dns_firewall_rule_group_name="${STACK_NAME}-rule-group"
firewall_params="${ARTIFACT_DIR}/dns_firewall_params.json"
aws_add_param_to_json "VpcId" "$vpc_id" "$firewall_params"
aws_add_param_to_json "FirewallRuleGroupName" "$dns_firewall_rule_group_name" "$firewall_params"
aws_add_param_to_json "DomainList" "${DOMAIN_LIST}" "$firewall_params"

echo "Create DNS firewall"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_dns_firewall.yaml)" \
  --parameters file://${firewall_params} &

wait "$!"
echo "Created stack"

# Save stack information to ${SHARED_DIR} for deprovision step
echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

# Wait for the DNS firewall to be ready
aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"
echo "${STACK_NAME}" > "${SHARED_DIR}/dns_firewall_stack_name"
aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/dns_firewall_stack_output"
echo "Finish DNS firewall provision"
