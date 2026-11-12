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
# rosa-e2e-hcp-shared-vpc-cleanup have run, verify that nothing is left behind
# in the shared AWS account or the cluster account. Not best-effort: an
# orphaned hosted zone, role or policy must fail the job so it is cleaned up
# by hand and the leak is noticed.

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

# verify_absent <description> <not-found marker> <aws args...>
# Only the service's specific not-found error proves deletion: any other AWS
# CLI failure (auth, network, throttling) must fail verification instead of
# reading as a PASS.
verify_absent() {
  local description="$1" not_found="$2"
  shift 2
  local out
  if out="$(aws "$@" 2>&1)"; then
    log "ERROR: ${description} still exists"
    ret=$((ret+1))
  elif grep -q "${not_found}" <<<"${out}"; then
    log "PASS: ${description} deleted"
  else
    log "ERROR: could not verify ${description}: ${out}"
    ret=$((ret+1))
  fi
}

HOSTED_ZONE_ID="$(head -n 1 "${HOSTED_ZONE_ID_FILE}" 2>/dev/null || true)"
if [[ -n "${HOSTED_ZONE_ID}" ]]; then
  verify_absent "private hosted zone ${HOSTED_ZONE_ID}" "NoSuchHostedZone" \
    route53 get-hosted-zone --id "${HOSTED_ZONE_ID}"
fi

ROLE_ARN="$(head -n 1 "${ROLE_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${ROLE_ARN}" ]]; then
  ROLE_NAME="${ROLE_ARN##*/}"
  verify_absent "shared VPC role ${ROLE_NAME}" "NoSuchEntity" \
    iam get-role --role-name "${ROLE_NAME}"
fi

POLICY_ARN="$(head -n 1 "${POLICY_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${POLICY_ARN}" ]]; then
  verify_absent "shared VPC policy ${POLICY_ARN}" "NoSuchEntity" \
    iam get-policy --policy-arn "${POLICY_ARN}"
fi

# HCP shared VPC resources (rosa-e2e-hcp-shared-vpc-prepare): the VPC endpoint
# role and policy and the internal communication hosted zone.
VPC_ENDPOINT_ROLE_ARN="$(head -n 1 "${VPC_ENDPOINT_ROLE_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${VPC_ENDPOINT_ROLE_ARN}" ]]; then
  VPC_ENDPOINT_ROLE_NAME="${VPC_ENDPOINT_ROLE_ARN##*/}"
  verify_absent "VPC endpoint role ${VPC_ENDPOINT_ROLE_NAME}" "NoSuchEntity" \
    iam get-role --role-name "${VPC_ENDPOINT_ROLE_NAME}"
fi

VPC_ENDPOINT_POLICY_ARN="$(head -n 1 "${VPC_ENDPOINT_POLICY_ARN_FILE}" 2>/dev/null || true)"
if [[ -n "${VPC_ENDPOINT_POLICY_ARN}" ]]; then
  verify_absent "VPC endpoint policy ${VPC_ENDPOINT_POLICY_ARN}" "NoSuchEntity" \
    iam get-policy --policy-arn "${VPC_ENDPOINT_POLICY_ARN}"
fi

INTERNAL_PHZ_ID="$(head -n 1 "${INTERNAL_PHZ_ID_FILE}" 2>/dev/null || true)"
if [[ -n "${INTERNAL_PHZ_ID}" ]]; then
  verify_absent "internal communication hosted zone ${INTERNAL_PHZ_ID}" "NoSuchHostedZone" \
    route53 get-hosted-zone --id "${INTERNAL_PHZ_ID}"
fi

# Cluster-account assume-role policies (<shared-role-name>-assume-role, created
# by rosa-e2e-hcp-shared-vpc-prepare and deleted best-effort by
# rosa-e2e-hcp-shared-vpc-cleanup): they live in the cluster account, so verify
# them with the main credentials before evaluating the result.
CLUSTER_AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -n "${ROLE_ARN}" || -n "${VPC_ENDPOINT_ROLE_ARN}" ]]; then
  if [[ ! -f "${CLUSTER_AWSCRED}" ]]; then
    log "ERROR: ${CLUSTER_AWSCRED} not found; cannot verify cluster-account assume-role policies"
    ret=$((ret+1))
  else
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_AWSCRED}"
    CLUSTER_ACCOUNT_ID="$(aws sts get-caller-identity --output text | awk '{print $1}')"
    for shared_role_arn in "${ROLE_ARN}" "${VPC_ENDPOINT_ROLE_ARN}"; do
      [[ -z "${shared_role_arn}" ]] && continue
      shared_role_name="${shared_role_arn##*/}"
      assume_policy_arn="arn:aws:iam::${CLUSTER_ACCOUNT_ID}:policy/${shared_role_name}-assume-role"
      verify_absent "cluster-account assume-role policy ${assume_policy_arn}" "NoSuchEntity" \
        iam get-policy --policy-arn "${assume_policy_arn}"
    done
  fi
fi

if [[ "${ret}" -ne 0 ]]; then
  log "ERROR: ${ret} orphaned shared VPC resource(s) left behind after teardown"
  exit 1
fi
log "Shared VPC teardown verification complete: no orphaned resources in the shared or cluster account"
