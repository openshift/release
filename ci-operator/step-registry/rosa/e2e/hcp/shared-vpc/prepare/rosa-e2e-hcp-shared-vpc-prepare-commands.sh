#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# HCP shared VPC preparation (ROSAENG-63353): creates every shared VPC
# resource rosa create cluster needs in the shared AWS account (the second
# account that holds the DNS, ${CLUSTER_PROFILE_DIR}/.awscred_shared_account):
# the ingress private hosted zone, the shared route53 role, and the
# HCP-only VPC endpoint role and internal communication hosted zone
# (rosa create cluster requires --vpc-endpoint-role-arn and
# --hcp-internal-communication-hosted-zone-id for Hosted Control Plane shared
# VPC clusters). The shared roles carry the AWS-managed policies
# ROSASharedVPCRoute53Policy and ROSASharedVPCEndpointPolicy, matching what a
# real rosa shared VPC setup grants. It also wires the cross-account trust:
# the shared roles trust the cluster account's installer and operator roles,
# and the cluster-account roles get the sts:AssumeRole permission policies
# (rosa create account-roles/operator-roles attaches those when run with the
# shared VPC flags; with pre-created roles we attach them directly).

REGION="${REGION:-${LEASED_RESOURCE}}"

SHARED_AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
if [[ ! -f "${SHARED_AWSCRED}" ]]; then
  log "ERROR: ${SHARED_AWSCRED} not found in the cluster profile;"
  log "       the shared VPC workflow requires a second AWS account for the shared resources"
  exit 1
fi

VPC_ID="$(head -n 1 "${SHARED_DIR}/vpc_id")"
rosa_dns_domain="$(head -n 1 "${SHARED_DIR}/rosa_dns_domain")"
if [[ -z "${VPC_ID}" || -z "${rosa_dns_domain}" ]]; then
  log "ERROR: vpc_id or rosa_dns_domain missing from ${SHARED_DIR};"
  log "       this step must run after aws-provision-vpc-shared and rosa-cluster-dnsdomain-create"
  exit 1
fi

# The PHZ and the IAM resources are named after the cluster (the ci-rosa-s
# prefix keeps the name within rosa's cluster name rules).
if [[ -s "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME="$(head -n 1 "${SHARED_DIR}/cluster-name")"
else
  CLUSTER_NAME="ci-rosa-s-$(openssl rand -hex 2)"
  echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
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

# Name the RAM-shared VPC after this job's cluster: aws-provision-vpc-shared
# tags it only with the job's stack name, which is not recognizable in the
# shared account's console.
aws ec2 create-tags --resources "${VPC_ID}" \
  --tags "Key=Name,Value=rosa-e2e-shared-vpc-${CLUSTER_NAME}"
log "Tagged shared VPC ${VPC_ID} as rosa-e2e-shared-vpc-${CLUSTER_NAME}"

# Ingress private hosted zone. Hosted Control Plane records live under
# rosa.<cluster>.<base-domain>, and OCM validates the zone name against
# cluster_domain_prefix.base_domain, so the zone must carry that exact name.
INGRESS_PHZ_NAME="rosa.${CLUSTER_NAME}.${rosa_dns_domain}"
INGRESS_PHZ_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${INGRESS_PHZ_NAME}" \
  --query "HostedZones[?Name=='${INGRESS_PHZ_NAME}.'].Id" --output text | awk -F / '{printf $NF}')"
if [[ -z "${INGRESS_PHZ_ID}" || "${INGRESS_PHZ_ID}" == "None" ]]; then
  INGRESS_ZONE_CREATION="$(aws route53 create-hosted-zone \
    --name "${INGRESS_PHZ_NAME}" \
    --vpc "VPCRegion=${REGION},VPCId=${VPC_ID}" \
    --caller-reference "${INGRESS_PHZ_NAME}-$(date +%s)")"
  INGRESS_PHZ_ID="$(jq -r '.HostedZone.Id' <<<"${INGRESS_ZONE_CREATION}" | awk -F / '{printf $3}')"
fi
echo "${INGRESS_PHZ_ID}" > "${SHARED_DIR}/hosted_zone_id"
log "Ingress private hosted zone: ${INGRESS_PHZ_ID} (${INGRESS_PHZ_NAME})"

# The shared route53 role carries the AWS-managed policy a real rosa shared
# VPC setup uses (route53 record changes on the rosa base-domain names, e.g.
# *.devshift.org / *.hypershift.local, plus reads and tag changes), instead
# of a hand-rolled customer-managed policy.
SHARED_ROUTE53_POLICY_ARN="arn:aws:iam::aws:policy/ROSASharedVPCRoute53Policy"

# Shared route53 role, trusting the installer and operator roles (in the
# classic workflow aws-provision-route53-private-hosted-zone creates the role
# and rosa-conf-shared-vpc-update-trust-policy replaces its trust with the
# installer and ingress-operator principals; HCP additionally needs the
# control-plane-operator principal).
ROUTE53_ROLE_NAME="${CLUSTER_NAME}-shared-role"
ROUTE53_TRUST_POLICY="$(jq -c -n \
  --arg installer "${INSTALLER_ROLE_ARN}" \
  --arg ingress "${INGRESS_OPERATOR_ROLE_ARN}" \
  --arg controlplane "${CONTROL_PLANE_OPERATOR_ROLE_ARN}" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Principal: {AWS: [$installer, $ingress, $controlplane]},
        Action: "sts:AssumeRole",
        Condition: {}
      }
    ]
  }')"
ROUTE53_ROLE_ARN="arn:aws:iam::${SHARED_ACCOUNT_ID}:role/${ROUTE53_ROLE_NAME}"
if ! aws iam get-role --role-name "${ROUTE53_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${ROUTE53_ROLE_NAME}" \
    --assume-role-policy-document "${ROUTE53_TRUST_POLICY}" >/dev/null
fi
# Publish the ARN as soon as the role exists so the best-effort cleanup step
# can delete it if trust or policy configuration below fails.
echo "${ROUTE53_ROLE_ARN}" > "${SHARED_DIR}/hosted_zone_role_arn"
aws iam update-assume-role-policy \
  --role-name "${ROUTE53_ROLE_NAME}" \
  --policy-document "${ROUTE53_TRUST_POLICY}"
aws iam attach-role-policy \
  --role-name "${ROUTE53_ROLE_NAME}" \
  --policy-arn "${SHARED_ROUTE53_POLICY_ARN}"
log "Route53 role ${ROUTE53_ROLE_ARN} trusts installer, ingress-operator and control-plane-operator"

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

# The VPC endpoint role carries the AWS-managed policy for the Hosted
# Control Plane cross-account VPC (the ec2 VPC-endpoint / security-group and
# route53 record permissions the control plane needs to wire it up), matching
# what rosa's PrepareSharedVPCEndPointRoleForHostedCP grants in production.
VPC_ENDPOINT_POLICY_ARN="arn:aws:iam::aws:policy/ROSASharedVPCEndpointPolicy"

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
VPC_ENDPOINT_ROLE_ARN="arn:aws:iam::${SHARED_ACCOUNT_ID}:role/${VPC_ENDPOINT_ROLE_NAME}"
if ! aws iam get-role --role-name "${VPC_ENDPOINT_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
    --assume-role-policy-document "${VPC_ENDPOINT_TRUST_POLICY}" >/dev/null
fi
# Publish the ARN as soon as the role exists so the best-effort cleanup step
# can delete it if trust or policy configuration below fails.
echo "${VPC_ENDPOINT_ROLE_ARN}" > "${SHARED_DIR}/vpc_endpoint_role_arn"
aws iam update-assume-role-policy \
  --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
  --policy-document "${VPC_ENDPOINT_TRUST_POLICY}"
aws iam attach-role-policy \
  --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
  --policy-arn "${VPC_ENDPOINT_POLICY_ARN}"
log "VPC endpoint role: ${VPC_ENDPOINT_ROLE_ARN}"

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
    --policy-arn "${policy_arn}"
}

for principal in "${INSTALLER_ROLE_ARN}" "${INGRESS_OPERATOR_ROLE_ARN}" "${CONTROL_PLANE_OPERATOR_ROLE_ARN}"; do
  attach_assume_role_policy "${principal}" "${ROUTE53_ROLE_ARN}"
done
for principal in "${INSTALLER_ROLE_ARN}" "${CONTROL_PLANE_OPERATOR_ROLE_ARN}"; do
  attach_assume_role_policy "${principal}" "${VPC_ENDPOINT_ROLE_ARN}"
done

log "HCP shared VPC preparation complete"
