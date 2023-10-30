#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}
CAPACITY=${CAPACITY:-100}

# Domain list
OCP_DOMAIN_ALLOW_LIST=$(echo -e '
  "registry.redhat.io",
  "access.redhat.com",
  ".quay.io",
  "sso.redhat.com",

  "cert-api.access.redhat.com",
  "api.access.redhat.com",
  "infogw.api.openshift.com",
  "console.redhat.com",

  "ec2.amazonaws.com",
  "events.amazonaws.com",
  "iam.amazonaws.com",
  "route53.amazonaws.com",
  "s3.amazonaws.com",
  "s3.'${REGION}'.amazonaws.com",
  "s3.dualstack.'${REGION}'.amazonaws.com",
  "sts.amazonaws.com",
  "sts.'${REGION}'.amazonaws.com",
  "tagging.us-east-1.amazonaws.com",
  "ec2.'${REGION}'.amazonaws.com",
  "elasticloadbalancing.'${REGION}'.amazonaws.com",
  "servicequotas.'${REGION}'.amazonaws.com",
  "tagging.'${REGION}'.amazonaws.com",

  "mirror.openshift.com",
  "storage.googleapis.com",
  "quayio-production-s3.s3.amazonaws.com",
  "api.openshift.com",
  "rhcos.mirror.openshift.com"
')

OSD_DOMAIN_ALLOW_LIST=$(echo -e '
  ".redhat.io",
  ".quay.io",
  "sso.redhat.com",
  "quay-registry.s3.amazonaws.com",
  "ocm-quay-production-s3.s3.amazonaws.com",
  "quayio-production-s3.s3.amazonaws.com",
  "cart-rhcos-ci.s3.amazonaws.com",
  "openshift.org",
  ".access.redhat.com",
  "registry.connect.redhat.com",
  "pull.q1w2.quay.rhcloud.com",
  ".q1w2.quay.rhcloud.com",
  "www.okd.io",
  "www.redhat.com",
  "aws.amazon.com",
  "catalog.redhat.com",

  "cert-api.access.redhat.com",
  "api.access.redhat.com",
  "infogw.api.openshift.com",
  "console.redhat.com",
  "cloud.redhat.com",
  "observatorium-mst.api.openshift.com",
  "observatorium.api.openshift.com",

  "ec2.amazonaws.com",
  "events.'${REGION}'.amazonaws.com",
  "iam.amazonaws.com",
  "route53.amazonaws.com",
  "sts.amazonaws.com",
  "sts.'${REGION}'.amazonaws.com",
  "tagging.us-east-1.amazonaws.com",
  "ec2.'${REGION}'.amazonaws.com",
  "elasticloadbalancing.'${REGION}'.amazonaws.com",
  "servicequotas.'${REGION}'.amazonaws.com",
  "tagging.'${REGION}'.amazonaws.com",

  "mirror.openshift.com",
  "storage.googleapis.com",
  "api.openshift.com",

  "api.pagerduty.com",
  "events.pagerduty.com",
  "api.deadmanssnitch.com",
  "nosnch.in",
  ".osdsecuritylogs.splunkcloud.com",
  "http-inputs-osdsecuritylogs.splunkcloud.com",
  "sftp.access.redhat.com"
')

DOMAIN_LIST=${OCP_DOMAIN_ALLOW_LIST}
if [[ ${MANAGED_CLUSTER} == "yes" ]]; then
  DOMAIN_LIST=${OSD_DOMAIN_ALLOW_LIST}
fi

# Create rule group
STACK_NAME=$(cat "${SHARED_DIR}/firewall_stack_name")
rule_group_name="${STACK_NAME}-rule-group"
RULE_GROUP_ALLOWED=$(echo -e '
{
  "RulesSource": {
    "RulesSourceList": {
      "Targets": ['${DOMAIN_LIST}'],
      "TargetTypes": [
        "TLS_SNI",
        "HTTP_HOST"
      ],
      "GeneratedRulesType": "ALLOWLIST"
    }
  }
}')

echo "Create the rule group for the network firewall $STACK_NAME"
ArnRuleGroup=$(aws --region $REGION network-firewall create-rule-group \
 --rule-group-name $rule_group_name \
 --type STATEFUL \
 --capacity ${CAPACITY} \
 --rule-group "$(echo $RULE_GROUP_ALLOWED | jq -c)" \
 --query "RuleGroupResponse.RuleGroupArn" --output=text)

# save rule group information to ${SHARED_DIR} for deprovision step
echo "${ArnRuleGroup}" > "${SHARED_DIR}/firewall_rule_group_arn"

# Add role group to the firewall policy
firewall_policy_update_token=$(cat "${SHARED_DIR}/firewall_policy_output" | jq -r '.UpdateToken')
firewall_policy_name=$(cat "${SHARED_DIR}/firewall_policy_output" | jq -r '.FirewallPolicyResponse.FirewallPolicyName')
FIREWALL_UPDATE_POLICY=$(echo -e '
{
  "StatefulRuleGroupReferences": [
    {
      "ResourceArn": "'${ArnRuleGroup}'"
    }
  ],
  "StatelessDefaultActions": [
    "aws:forward_to_sfe"
  ],
  "StatelessFragmentDefaultActions": [
    "aws:forward_to_sfe"
  ]
}')

echo "Add the rule group to the network firewall policy $firewall_policy_name"
aws --region $REGION network-firewall update-firewall-policy \
 --update-token $firewall_policy_update_token \
 --firewall-policy-name $firewall_policy_name \
 --firewall-policy "$(echo $FIREWALL_UPDATE_POLICY | jq -c)"

# Sleep 30 to wait for syncing role group
sleep 30

cp "${SHARED_DIR}/firewall_rule_group_arn" "${ARTIFACT_DIR}/"
