#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Post-phase cleanup for the HCP shared VPC resources created by
# rosa-e2e-hcp-shared-vpc-prepare and rosa-e2e-hcp-shared-vpc-trust
# (ROSAENG-63353): the ingress private hosted zone, the shared route53 role,
# the internal communication hosted zone and the VPC endpoint role in the
# shared account, and the assume-role permission policies in the cluster
# account. The shared roles carry AWS-managed
# policies (ROSASharedVPCRoute53Policy / ROSASharedVPCEndpointPolicy), which
# are only detached, never deleted. Best-effort: the non-best-effort orphan
# gate rosa-e2e-validate-shared-vpc-teardown runs after this step and fails
# the job if anything survived.

REGION="${REGION:-${LEASED_RESOURCE}}"

VPC_ENDPOINT_ROLE_ARN="$(head -n 1 "${SHARED_DIR}/vpc_endpoint_role_arn" 2>/dev/null || true)"
INTERNAL_PHZ_ID="$(head -n 1 "${SHARED_DIR}/hcp_internal_communication_hosted_zone_id" 2>/dev/null || true)"
ROUTE53_ROLE_ARN="$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn" 2>/dev/null || true)"
HOSTED_ZONE_ID="$(head -n 1 "${SHARED_DIR}/hosted_zone_id" 2>/dev/null || true)"

if [[ -z "${VPC_ENDPOINT_ROLE_ARN}" && -z "${INTERNAL_PHZ_ID}" && -z "${HOSTED_ZONE_ID}" ]]; then
  log "No HCP shared VPC inputs in ${SHARED_DIR}; nothing to clean up"
  exit 0
fi

delete_hosted_zone() {
  local zone_id="$1"
  LEFTOVER_RECORDS="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' \
    --output json 2>/dev/null || echo "[]")"
  if [[ "$(jq length <<<"${LEFTOVER_RECORDS}")" != "0" ]]; then
    log "WARNING: hosted zone ${zone_id} still has records, deleting them first"
    CHANGE_FILE="$(mktemp)"
    jq '{Changes: [.[] | {Action: "DELETE", ResourceRecordSet: .}]}' <<<"${LEFTOVER_RECORDS}" > "${CHANGE_FILE}"
    aws route53 change-resource-record-sets \
      --hosted-zone-id "${zone_id}" \
      --change-batch "file://${CHANGE_FILE}" 2>/dev/null || true
    rm -f "${CHANGE_FILE}"
  fi
  aws route53 delete-hosted-zone --id "${zone_id}" 2>/dev/null \
    || log "WARNING: failed to delete hosted zone ${zone_id}"
}

# --- Cluster-account permission policies (main AWS account) ---
# Delete the assume-role policies first: they reference the shared-account
# roles and are attached to the cluster-account roles.
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${REGION}"
export AWS_REGION="${REGION}"
CLUSTER_ACCOUNT_ID="$(aws sts get-caller-identity --output text | awk '{print $1}')"

for shared_role_arn in "${ROUTE53_ROLE_ARN}" "${VPC_ENDPOINT_ROLE_ARN}"; do
  [[ -z "${shared_role_arn}" ]] && continue
  shared_role_name="${shared_role_arn##*/}"
  policy_arn="arn:aws:iam::${CLUSTER_ACCOUNT_ID}:policy/${shared_role_name}-assume-role"
  if aws iam get-policy --policy-arn "${policy_arn}" >/dev/null 2>&1; then
    for attached_role in $(aws iam list-entities-for-policy --policy-arn "${policy_arn}" \
      --query 'PolicyRoles[].RoleName' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "${attached_role}" --policy-arn "${policy_arn}" 2>/dev/null || true
    done
    aws iam delete-policy --policy-arn "${policy_arn}" 2>/dev/null \
      || log "WARNING: failed to delete policy ${policy_arn}"
  fi
done

# --- Shared-account resources (second AWS account) ---
SHARED_AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
if [[ ! -f "${SHARED_AWSCRED}" ]]; then
  log "ERROR: ${SHARED_AWSCRED} not found in the cluster profile; cannot clean up the shared-account resources"
  exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="${SHARED_AWSCRED}"

if [[ -n "${HOSTED_ZONE_ID}" ]]; then
  log "Deleting ingress private hosted zone ${HOSTED_ZONE_ID}"
  delete_hosted_zone "${HOSTED_ZONE_ID}"
fi

if [[ -n "${INTERNAL_PHZ_ID}" ]]; then
  log "Deleting internal communication hosted zone ${INTERNAL_PHZ_ID}"
  delete_hosted_zone "${INTERNAL_PHZ_ID}"
fi

if [[ -n "${ROUTE53_ROLE_ARN}" ]]; then
  ROUTE53_ROLE_NAME="${ROUTE53_ROLE_ARN##*/}"
  log "Deleting shared route53 role ${ROUTE53_ROLE_NAME}"
  # The AWS-managed policy is detached (not deleted) so the role can be removed.
  aws iam detach-role-policy --role-name "${ROUTE53_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/ROSASharedVPCRoute53Policy" 2>/dev/null || true
  aws iam delete-role --role-name "${ROUTE53_ROLE_NAME}" 2>/dev/null \
    || log "WARNING: failed to delete role ${ROUTE53_ROLE_NAME}"
fi

if [[ -n "${VPC_ENDPOINT_ROLE_ARN}" ]]; then
  VPC_ENDPOINT_ROLE_NAME="${VPC_ENDPOINT_ROLE_ARN##*/}"
  log "Deleting VPC endpoint role ${VPC_ENDPOINT_ROLE_NAME}"
  aws iam detach-role-policy --role-name "${VPC_ENDPOINT_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/ROSASharedVPCEndpointPolicy" 2>/dev/null || true
  aws iam delete-role --role-name "${VPC_ENDPOINT_ROLE_NAME}" 2>/dev/null \
    || log "WARNING: failed to delete role ${VPC_ENDPOINT_ROLE_NAME}"
fi

log "HCP shared VPC cleanup complete"
