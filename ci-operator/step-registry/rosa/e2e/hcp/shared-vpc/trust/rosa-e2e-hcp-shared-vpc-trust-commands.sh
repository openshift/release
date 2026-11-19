#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# HCP shared VPC trust configuration (ROSAENG-63353): the second half of
# rosa-e2e-hcp-shared-vpc-prepare. The prepare step creates the shared roles
# BEFORE the rosa-sts-oidc-config-create chain, so that
# rosa-sts-operator-roles-create (ENABLE_SHARED_VPC=yes) finds
# ${SHARED_DIR}/hosted_zone_role_arn and passes --shared-vpc-role-arn to rosa
# create operator-roles; at that point the cluster account's installer and
# operator roles do not exist yet, so the roles carry a placeholder trust.
# This step runs after the chain and completes the cross-account wiring:
# it replaces the placeholder trust with the installer and operator role
# principals, and attaches the cluster-account sts:AssumeRole permission
# policies to those roles (what rosa create account-roles/operator-roles
# attaches when run with the shared VPC flags; with the roles created by the
# chain we attach the policies directly).

REGION="${REGION:-${LEASED_RESOURCE}}"

# Shared-account role ARNs (written by rosa-e2e-hcp-shared-vpc-prepare).
ROUTE53_ROLE_ARN="$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn" 2>/dev/null || true)"
VPC_ENDPOINT_ROLE_ARN="$(head -n 1 "${SHARED_DIR}/vpc_endpoint_role_arn" 2>/dev/null || true)"
if [[ -z "${ROUTE53_ROLE_ARN}" || -z "${VPC_ENDPOINT_ROLE_ARN}" ]]; then
  log "ERROR: hosted_zone_role_arn or vpc_endpoint_role_arn missing from ${SHARED_DIR};"
  log "       this step must run after rosa-e2e-hcp-shared-vpc-prepare"
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

# --- Shared account: replace the placeholder trust with the real principals ---
SHARED_AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
if [[ ! -f "${SHARED_AWSCRED}" ]]; then
  log "ERROR: ${SHARED_AWSCRED} not found in the cluster profile;"
  log "       the shared VPC workflow requires a second AWS account for the shared resources"
  exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="${SHARED_AWSCRED}"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_REGION="${REGION}"

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
aws iam update-assume-role-policy \
  --role-name "${ROUTE53_ROLE_ARN##*/}" \
  --policy-document "${ROUTE53_TRUST_POLICY}"
log "Route53 role ${ROUTE53_ROLE_ARN} now trusts installer, ingress-operator and control-plane-operator"

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
aws iam update-assume-role-policy \
  --role-name "${VPC_ENDPOINT_ROLE_ARN##*/}" \
  --policy-document "${VPC_ENDPOINT_TRUST_POLICY}"
log "VPC endpoint role ${VPC_ENDPOINT_ROLE_ARN} now trusts installer and control-plane-operator"

# --- Cluster-account permission policies (main AWS account) ---
# IAM needs an sts:AssumeRole grant on the assuming side too. rosa names these
# <shared-role-name>-assume-role (AssumeRolePolicyPrefix).
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CLUSTER_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

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

log "HCP shared VPC trust configuration complete"
