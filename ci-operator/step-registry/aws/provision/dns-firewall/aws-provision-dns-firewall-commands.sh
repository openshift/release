#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

function aws_add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

# Get the VPC ID
vpc_id=$(head -n 1 ${SHARED_DIR}/vpc_id)
if [[ -z $vpc_id ]]; then
  echo "Error: Can not get VPC id, exit"
  echo "vpc: $vpc_id"
  exit 1
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# Domain list
firewall_list=${ARTIFACT_DIR}/dns_firewall_allowd_list.txt
cat > ${firewall_list} << EOF
*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
1.rhel.pool.ntp.org
2.rhel.pool.ntp.org
3.rhel.pool.ntp.org
access.redhat.com
api.access.redhat.com
api.openshift.com
aws.amazon.com
cdn.quay.io
cdn01.quay.io
cdn02.quay.io
cdn03.quay.io
cert-api.access.redhat.com
console.redhat.com
ec2.${REGION}.amazonaws.com
ec2.amazonaws.com
elasticloadbalancing.${REGION}.amazonaws.com
events.amazonaws.com
iam.amazonaws.com
infogw.api.openshift.com
mirror.openshift.com
oso-rhc4tp-docker-registry.s3-us-west-2.amazonaws.com
quay.io
quayio-production-s3.s3.amazonaws.com
registry.connect.redhat.com
registry.redhat.io
rhc4tp-prod-z8cxf-image-registry-us-east-1-evenkyleffocxqvofrk.s3.dualstack.us-east-1.amazonaws.com
rhcos.mirror.openshift.com
route53.amazonaws.com
s3.${REGION}.amazonaws.com
s3.amazonaws.com
s3.dualstack.${REGION}.amazonaws.com
servicequotas.${REGION}.amazonaws.com
sso.redhat.com
storage.googleapis.com
sts.${REGION}.amazonaws.com
sts.amazonaws.com
tagging.${REGION}.amazonaws.com
tagging.us-east-1.amazonaws.com
EOF

# Prow CI
echo "*.openshiftapps.com" >> ${firewall_list}

if [[ ${IS_MANAGED_CLUSTER} == "yes" ]]; then
    echo "events.${REGION}.amazonaws.com" >> ${firewall_list}
fi

echo "Firewall List:"
cat $firewall_list

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

STACK_NAME="${CLUSTER_NAME}-dns-firewall"
dns_firewall_rule_group_name="${STACK_NAME}-rule-group"
firewall_params="${ARTIFACT_DIR}/dns_firewall_params.json"
aws_add_param_to_json "VpcId" "$vpc_id" "$firewall_params"
aws_add_param_to_json "FirewallRuleGroupName" "$dns_firewall_rule_group_name" "$firewall_params"

domain_list_value=$(cat ${firewall_list} | sort | uniq | sed '/^[[:space:]]*$/d' | sed -z 's/\n/,/g' | sed 's/,$//')
echo "DomainList parameter value:"
echo ${domain_list_value}
aws_add_param_to_json "DomainList" "${domain_list_value}" "$firewall_params"

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
cat "${SHARED_DIR}/dns_firewall_stack_output"
echo "Finish DNS firewall provision"