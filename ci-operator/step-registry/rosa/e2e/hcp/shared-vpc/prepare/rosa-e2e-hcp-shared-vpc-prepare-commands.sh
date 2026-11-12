#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# HCP shared VPC preparation (ROSAENG-63353): rosa create cluster requires
# --vpc-endpoint-role-arn and --hcp-internal-communication-hosted-zone-id for
# Hosted Control Plane shared VPC clusters. This step creates those resources
# in the shared AWS account (the same account that holds the private hosted
# zone and the shared route53 role from aws-provision-route53-private-hosted-zone),
# adds the control-plane-operator role to the route53 role's trust principals,
# and attaches the sts:AssumeRole permission policies to the cluster-account
# roles (rosa create account-roles/operator-roles does this when given the
# shared VPC flags; with pre-created roles we attach them directly).

REGION="${REGION:-${LEASED_RESOURCE}}"

SHARED_AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
if [[ ! -f "${SHARED_AWSCRED}" ]]; then
  log "ERROR: ${SHARED_AWSCRED} not found; HCP shared VPC needs a second AWS account"
  exit 1
fi

CLUSTER_NAME="$(head -n 1 "${SHARED_DIR}/cluster-name")"
VPC_ID="$(head -n 1 "${SHARED_DIR}/vpc_id")"
ROUTE53_ROLE_ARN="$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn")"
if [[ -z "${CLUSTER_NAME}" || -z "${VPC_ID}" || -z "${ROUTE53_ROLE_ARN}" ]]; then
  log "ERROR: cluster-name, vpc_id or hosted_zone_role_arn missing from ${SHARED_DIR};"
  log "       this step must run after aws-provision-route53-private-hosted-zone"
  exit 1
fi

# Principals from the cluster account: the installer account role and the
# ingress / control-plane operator roles (written by rosa-sts-account-roles-create
# and rosa-sts-operator-roles-create).
INSTALLER_ROLE_ARN="$(cat "${SHARED_DIR}/account-roles-arns" | { grep "Installer-Role" || true; })"
INGRESS_OPERATOR_ROLE_ARN="$(cat "${SHARED_DIR}/operator-roles-arns" | { grep "openshift-ingress-operator-cloud-credentials" || true; })"
CONTROL_PLANE_OPERATOR_ROLE_ARN="$(cat "${SHARED_DIR}/operator-roles-arns" | { grep "kube-system-control-plane-operator" || true; })"
if [[ -z "${INSTALLER_ROLE_ARN}" || -z "${INGRESS_OPERATOR_ROLE_ARN}" || -z "${CONTROL_PLANE_OPERATOR_ROLE_ARN}" ]]; then
  log "ERROR: could not resolve the installer / ingress-operator / control-plane-operator role ARNs"
  log "       from ${SHARED_DIR}/account-roles-arns and ${SHARED_DIR}/operator-roles-arns;"
  log "       this step must run after the rosa-sts-oidc-config-create chain"
  exit 1
fi

# --- Shared-account resources (second AWS account) ---
export AWS_SHARED_CREDENTIALS_FILE="${SHARED_AWSCRED}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_REGION="${REGION}"

SHARED_ACCOUNT_ID="$(aws sts get-caller-identity --output text | awk '{print $1}')"

# Internal communication hosted zone (<cluster>.hypershift.local), associated
# with the same VPC as the ingress private hosted zone (reuse on re-run).
INTERNAL_PHZ_NAME="${CLUSTER_NAME}.hypershift.local"
INTERNAL_PHZ_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${INTERNAL_PHZ_NAME}" \
  --query "HostedZones[?Name=='${INTERNAL_PHZ_NAME}.'].Id" --output text | awk -F / '{printf $NF}')"
if [[ -z "${INTERNAL_PHZ_ID}" || "${INTERNAL_PHZ_ID}" == "None" ]]; then
  INTERNAL_ZONE_CREATION="$(aws route53 create-hosted-zone \
    --name "${INTERNAL_PHZ_NAME}" \
    --vpc "VPCRegion=${REGION},VPCId=${VPC_ID}" \
    --caller-reference "${INTERNAL_PHZ_NAME}-$(date +%s)")"
  INTERNAL_PHZ_ID="$(jq -r '.HostedZone.Id' <<<"${INTERNAL_ZONE_CREATION}" | awk -F / '{printf $3}')"
fi
echo "${INTERNAL_PHZ_ID}" > "${SHARED_DIR}/hcp_internal_communication_hosted_zone_id"
log "Internal communication hosted zone: ${INTERNAL_PHZ_ID} (${INTERNAL_PHZ_NAME})"

# VPC endpoint policy: the ec2 VPC-endpoint / security-group and route53 record
# permissions the control plane needs to wire up the cross-account VPC
# (mirrors rosa's PrepareSharedVPCEndPointRoleForHostedCP).
VPC_ENDPOINT_POLICY_NAME="${CLUSTER_NAME}-sharedvpc-vpc-endpoint-policy"
VPC_ENDPOINT_POLICY_ARN="arn:aws:iam::${SHARED_ACCOUNT_ID}:policy/${VPC_ENDPOINT_POLICY_NAME}"
if ! aws iam get-policy --policy-arn "${VPC_ENDPOINT_POLICY_ARN}" >/dev/null 2>&1; then
  VPC_ENDPOINT_POLICY_ARN="$(aws iam create-policy \
    --policy-name "${VPC_ENDPOINT_POLICY_NAME}" \
    --query 'Policy.Arn' --output text \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "ec2:CreateVpcEndpoint", "ec2:DescribeVpcEndpoints", "ec2:ModifyVpcEndpoint",
            "ec2:DeleteVpcEndpoints", "ec2:CreateTags", "ec2:CreateSecurityGroup",
            "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
            "ec2:DeleteSecurityGroup", "ec2:RevokeSecurityGroupIngress",
            "ec2:RevokeSecurityGroupEgress", "ec2:DescribeSecurityGroups",
            "ec2:DescribeVpcs", "route53:ListHostedZones",
            "route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"
          ],
          "Resource": "*"
        }
      ]
    }')"
fi
echo "${VPC_ENDPOINT_POLICY_ARN}" > "${SHARED_DIR}/vpc_endpoint_policy_arn"
log "VPC endpoint policy: ${VPC_ENDPOINT_POLICY_ARN}"

# VPC endpoint role trusting the installer and control-plane-operator roles
VPC_ENDPOINT_ROLE_NAME="${CLUSTER_NAME}-shared-vpcendpoint-role"
VPC_ENDPOINT_TRUST_POLICY="$(jq -c -n \
  --arg installer "${INSTALLER_ROLE_ARN}" --arg controlplane "${CONTROL_PLANE_OPERATOR_ROLE_ARN}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Principal: {AWS: [$installer, $controlplane]},
        Action: "sts:AssumeRole",
        Condition: {}
      }
    ]
  }')"
if ! aws iam get-role --role-name "${VPC_ENDPOINT_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
    --assume-role-policy-document "${VPC_ENDPOINT_TRUST_POLICY}" >/dev/null
fi
aws iam update-assume-role-policy \
  --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
  --policy-document "${VPC_ENDPOINT_TRUST_POLICY}"
aws iam attach-role-policy \
  --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
  --policy-arn "${VPC_ENDPOINT_POLICY_ARN}" 2>/dev/null || true
VPC_ENDPOINT_ROLE_ARN="arn:aws:iam::${SHARED_ACCOUNT_ID}:role/${VPC_ENDPOINT_ROLE_NAME}"
echo "${VPC_ENDPOINT_ROLE_ARN}" > "${SHARED_DIR}/vpc_endpoint_role_arn"
log "VPC endpoint role: ${VPC_ENDPOINT_ROLE_ARN}"

# Add the control-plane-operator role to the shared route53 role's trust
# principals (the installer and ingress-operator principals are already there,
# added by rosa-conf-shared-vpc-update-trust-policy).
ROUTE53_ROLE_NAME="${ROUTE53_ROLE_ARN##*/}"
CURRENT_TRUST="$(aws iam get-role --role-name "${ROUTE53_ROLE_NAME}" --query 'Role.AssumeRolePolicyDocument' --output json)"
UPDATED_TRUST="$(jq -c --arg controlplane "${CONTROL_PLANE_OPERATOR_ROLE_ARN}" \
  'if (.Statement[0].Principal.AWS | index($controlplane)) then . else .Statement[0].Principal.AWS += [$controlplane] end' \
  <<<"${CURRENT_TRUST}")"
aws iam update-assume-role-policy \
  --role-name "${ROUTE53_ROLE_NAME}" \
  --policy-document "${UPDATED_TRUST}"
log "Route53 role ${ROUTE53_ROLE_NAME} now trusts installer, ingress-operator and control-plane-operator"

# --- Cluster-account permission policies (main AWS account) ---
# IAM needs an sts:AssumeRole grant on the assuming side too. rosa names these
# <shared-role-name>-assume-role (AssumeRolePolicyPrefix).
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CLUSTER_ACCOUNT_ID="$(aws sts get-caller-identity --output text | awk '{print $1}')"

attach_assume_role_policy() {
  local target_role_arn="$1" shared_role_arn="$2"
  local target_role_name="${target_role_arn##*/}"
  local shared_role_name="${shared_role_arn##*/}"
  local policy_arn="arn:aws:iam::${CLUSTER_ACCOUNT_ID}:policy/${shared_role_name}-assume-role"
  if ! aws iam get-policy --policy-arn "${policy_arn}" >/dev/null 2>&1; then
    policy_arn="$(aws iam create-policy \
      --policy-name "${shared_role_name}-assume-role" \
      --query 'Policy.Arn' --output text \
      --policy-document "{\"Version\": \"2012-10-17\", \"Statement\": {\"Effect\": \"Allow\", \"Action\": \"sts:AssumeRole\", \"Resource\": \"${shared_role_arn}\"}}")"
  fi
  aws iam attach-role-policy \
    --role-name "${target_role_name}" \
    --policy-arn "${policy_arn}" 2>/dev/null || true
}

for principal in "${INSTALLER_ROLE_ARN}" "${INGRESS_OPERATOR_ROLE_ARN}" "${CONTROL_PLANE_OPERATOR_ROLE_ARN}"; do
  attach_assume_role_policy "${principal}" "${ROUTE53_ROLE_ARN}"
done
for principal in "${INSTALLER_ROLE_ARN}" "${CONTROL_PLANE_OPERATOR_ROLE_ARN}"; do
  attach_assume_role_policy "${principal}" "${VPC_ENDPOINT_ROLE_ARN}"
done

log "HCP shared VPC preparation complete"
