#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Post-teardown orphan gate for shared VPC clusters (ROSAENG-63353,
# ROSAENG-61409): after rosa-cluster-deprovision and
# aws-deprovision-route53-private-hosted-zone have run, verify that nothing
# is left behind in the shared AWS account. Not best-effort: an orphaned
# hosted zone, role or policy must fail the job so it is cleaned up by hand
# and the leak is noticed.

HOSTED_ZONE_ID_FILE="${SHARED_DIR}/hosted_zone_id"
ROLE_ARN_FILE="${SHARED_DIR}/hosted_zone_role_arn"
POLICY_ARN_FILE="${SHARED_DIR}/shared_install_policy_arn"
VPC_ENDPOINT_ROLE_ARN_FILE="${SHARED_DIR}/vpc_endpoint_role_arn"
VPC_ENDPOINT_POLICY_ARN_FILE="${SHARED_DIR}/vpc_endpoint_policy_arn"
INTERNAL_PHZ_ID_FILE="${SHARED_DIR}/hcp_internal_communication_hosted_zone_id"

# Clusters not provisioned with a shared VPC write none of these files.
if [[ ! -s "${HOSTED_ZONE_ID_FILE}" && ! -s "${ROLE_ARN_FILE}" && ! -s "${POLICY_ARN_FILE}" && \
   ! -s "${VPC_ENDPOINT_ROLE_ARN_FILE}" && ! -s "${VPC_ENDPOINT_POLICY_ARN_FILE}" && ! -s "${INTERNAL_PHZ_ID_FILE}" ]]; then
  log "No shared VPC inputs in ${SHARED_DIR}; cluster was not provisioned with a shared VPC, nothing to verify"
  exit 0
fi

SHARED_AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
if [[ ! -f "${SHARED_AWSCRED}" ]]; then
  log "ERROR: shared VPC inputs present but ${SHARED_AWSCRED} not found;"
  log "       cannot verify the shared account for orphaned resources"
  exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="${SHARED_AWSCRED}"
export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE}}"
export AWS_REGION="${REGION:-${LEASED_RESOURCE}}"

ret=0

HOSTED_ZONE_ID="$(head -n 1 "${HOSTED_ZONE_ID_FILE}" 2>/dev/null || true)"
if [[ -n "${HOSTED_ZONE_ID}" ]]; then
  if aws route53 get-hosted-zone --id "${HOSTED_ZONE_ID}" >/dev/null 2>&1; then
    log "ERROR: private hosted zone ${HOSTED_ZONE_ID} still exists in the shared account"
    ret=$((ret+1))
  else
    log "PASS: private hosted zone ${HOSTED_ZONE_ID} deleted"
  fi
fi

ROLE_ARN="$(head -n 1 "${ROLE_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${ROLE_ARN}" ]]; then
  ROLE_NAME="${ROLE_ARN##*/}"
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    log "ERROR: shared VPC role ${ROLE_NAME} still exists in the shared account"
    ret=$((ret+1))
  else
    log "PASS: shared VPC role ${ROLE_NAME} deleted"
  fi
fi

POLICY_ARN="$(head -n 1 "${POLICY_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${POLICY_ARN}" ]]; then
  if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
    log "ERROR: shared VPC policy still exists in the shared account"
    ret=$((ret+1))
  else
    log "PASS: shared VPC policy deleted"
  fi
fi

# HCP shared VPC resources (rosa-e2e-hcp-shared-vpc-prepare): the VPC endpoint
# role and policy and the internal communication hosted zone.
VPC_ENDPOINT_ROLE_ARN="$(head -n 1 "${VPC_ENDPOINT_ROLE_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${VPC_ENDPOINT_ROLE_ARN}" ]]; then
  VPC_ENDPOINT_ROLE_NAME="${VPC_ENDPOINT_ROLE_ARN##*/}"
  if aws iam get-role --role-name "${VPC_ENDPOINT_ROLE_NAME}" >/dev/null 2>&1; then
    log "ERROR: VPC endpoint role ${VPC_ENDPOINT_ROLE_NAME} still exists in the shared account"
    ret=$((ret+1))
  else
    log "PASS: VPC endpoint role ${VPC_ENDPOINT_ROLE_NAME} deleted"
  fi
fi

VPC_ENDPOINT_POLICY_ARN="$(head -n 1 "${VPC_ENDPOINT_POLICY_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${VPC_ENDPOINT_POLICY_ARN}" ]]; then
  if aws iam get-policy --policy-arn "${VPC_ENDPOINT_POLICY_ARN}" >/dev/null 2>&1; then
    log "ERROR: VPC endpoint policy still exists in the shared account"
    ret=$((ret+1))
  else
    log "PASS: VPC endpoint policy deleted"
  fi
fi

INTERNAL_PHZ_ID="$(head -n 1 "${INTERNAL_PHZ_ID_FILE}" 2>/dev/null || true)"
if [[ -n "${INTERNAL_PHZ_ID}" ]]; then
  if aws route53 get-hosted-zone --id "${INTERNAL_PHZ_ID}" >/dev/null 2>&1; then
    log "ERROR: internal communication hosted zone ${INTERNAL_PHZ_ID} still exists in the shared account"
    ret=$((ret+1))
  else
    log "PASS: internal communication hosted zone ${INTERNAL_PHZ_ID} deleted"
  fi
fi

if [[ "${ret}" -ne 0 ]]; then
  log "ERROR: ${ret} orphaned shared VPC resource(s) left in the shared account after teardown"
  exit 1
fi
log "Shared VPC teardown verification complete: no orphaned resources in the shared account"
