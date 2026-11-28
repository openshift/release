#!/bin/bash

# Compare the AWS account reachable with this job's cluster profile credentials
# against an independent, authoritative reference for the account that owns the
# cluster, and publish the result next to the AWS failure context captured by
# the conformance step.
#
# This step is a no-op unless the conformance step ran with
# AWS_FAILURE_DIAGNOSTICS=true and left a context document in ${SHARED_DIR}.
#
# Safety contract:
#   * Account IDs and role ARNs are compared in shell variables and are never
#     written to the artifact, to stdout or to stderr. Only an enum status, a
#     reason code and the name of the reference source are published.
#   * Tracing is never enabled, and the AWS CLI's stderr is discarded so that a
#     credential path or token in an error message cannot reach the log.
#   * The step always exits 0 so that best-effort cleanup is preserved.
#
# Provenance caveat, deliberately recorded in the output: this runs in a post
# pod after the failure, so the identity it reads is NOT an observation of the
# credential chain that was in effect inside the test process at the time of the
# original AWS call. It is the identity of the same credential *file path* the
# conformance step reported, read at comparison_observed_at. When the
# conformance step could not prove that the test process would use that file,
# the comparison is reported as unknown rather than as a match.

set -o nounset
set -o pipefail

SHARED="${SHARED_DIR:-/nonexistent}"
# The conformance step leaves the handoff at the top level of ${SHARED_DIR}:
# ci-operator persists that directory with util.SecretFromDir, which skips
# subdirectories, so a nested path would never arrive here.
CONTEXT_FILE="${SHARED}/aws-failure-diagnostics-test-context.json"
OUT_DIR="${ARTIFACT_DIR:-/tmp}/aws-failure-diagnostics"
AWSCRED="${CLUSTER_PROFILE_DIR:-/nonexistent}/.awscred"

if [[ ! -s "${CONTEXT_FILE}" ]]; then
  echo "rosa-aws-hcp-diagnose-aws-identity: no AWS failure context in SHARED_DIR, nothing to do"
  exit 0
fi

if ! jq -e . "${CONTEXT_FILE}" >/dev/null 2>&1; then
  echo "rosa-aws-hcp-diagnose-aws-identity: AWS failure context is not valid JSON, nothing to do"
  exit 0
fi

mkdir -p "${OUT_DIR}" || exit 0

COMPARISON_OBSERVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CHAIN_PROVABLE="$(jq -r '.credential_context.effective_credential_chain_provable // false' "${CONTEXT_FILE}")"
CHAIN_REASON="$(jq -r '.credential_context.unprovable_reason // "unknown"' "${CONTEXT_FILE}")"

# Region used for the STS call only. STS is global, but the CLI requires a
# region to be resolvable. This never influences the test, which has already
# finished.
STS_REGION="${REGION:-}"
if [[ -z "${STS_REGION}" ]]; then
  STS_REGION="$(jq -r '.region_evidence.configured.cluster_config_region.value // empty' "${CONTEXT_FILE}")"
fi
if [[ -z "${STS_REGION}" ]]; then
  leased="${LEASED_RESOURCE:-}"
  STS_REGION="${leased%%--*}"
fi

# Caller account: read once, kept in a variable, never printed.
caller_account=""
caller_status="unavailable"
if [[ ! -f "${AWSCRED}" ]]; then
  caller_status="credential-file-absent"
elif ! command -v aws >/dev/null 2>&1; then
  caller_status="aws-cli-absent"
else
  if caller_account="$(AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}" \
    AWS_DEFAULT_REGION="${STS_REGION}" \
    AWS_MAX_ATTEMPTS=2 AWS_RETRY_MODE=standard \
    timeout 60 aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    if [[ "${caller_account}" =~ ^[0-9]{12}$ ]]; then
      caller_status="read"
    else
      caller_account=""
      caller_status="malformed-response"
    fi
  else
    caller_account=""
    caller_status="sts-call-failed"
  fi
fi

# Expected account: an independent, authoritative reference recorded during
# provisioning, naming the AWS account the cluster's resources were created in.
# Tried in order; only the source name is published.
expected_account=""
reference_source="none"
reference_status="missing"

# Prints the 12-digit account field of an IAM ARN read from stdin, and nothing
# else; the ARN itself is never printed. The installer role is preferred, the
# way the sibling ROSA steps select it, so that in a shared-VPC layout an ARN
# belonging to the VPC-owning account cannot be mistaken for the account that
# owns the cluster.
extract_account_from_arn() {
  local arns installer
  arns="$(sed -n -E 's#.*(arn:aws[a-zA-Z-]*:iam::[0-9]{12}:[^[:space:]",]*).*#\1#p')"
  installer="$(printf '%s\n' "${arns}" | grep -m1 'Installer-Role' || true)"
  if [[ -z "${installer}" ]]; then
    installer="$(printf '%s\n' "${arns}" | head -n 1)"
  fi
  printf '%s\n' "${installer}" | sed -n -E 's#arn:aws[a-zA-Z-]*:iam::([0-9]{12}):.*#\1#p' | head -n 1
}

ROLES_FILE="${SHARED}/account-roles-arns"
CLUSTER_CONFIG="${SHARED}/cluster-config"

if [[ -s "${ROLES_FILE}" ]]; then
  reference_source="shared-dir-account-roles-arns"
  expected_account="$(extract_account_from_arn < "${ROLES_FILE}")"
  reference_status="malformed"
fi

if [[ ! "${expected_account}" =~ ^[0-9]{12}$ ]] && [[ -s "${CLUSTER_CONFIG}" ]]; then
  role_arn="$(jq -r '.aws.sts.role_arn // empty' "${CLUSTER_CONFIG}" 2>/dev/null)"
  if [[ -n "${role_arn}" ]]; then
    reference_source="shared-dir-cluster-config-role-arn"
    expected_account="$(printf '%s\n' "${role_arn}" | extract_account_from_arn)"
    reference_status="malformed"
  fi
fi

if [[ "${expected_account}" =~ ^[0-9]{12}$ ]]; then
  reference_status="read"
else
  expected_account=""
  if [[ "${reference_source}" == "none" ]]; then
    reference_status="missing"
  fi
fi

# Comparison. An unprovable credential chain forces "unknown" even when the two
# values are identical, because the test process may not have used this file.
match_status="unknown"
match_reason=""
if [[ "${reference_status}" != "read" ]]; then
  match_status="unknown"
  match_reason="expected-account-reference-${reference_status}"
elif [[ "${caller_status}" != "read" ]]; then
  match_status="unknown"
  match_reason="caller-identity-${caller_status}"
elif [[ "${CHAIN_PROVABLE}" != "true" ]]; then
  match_status="unknown"
  match_reason="test-credential-chain-unprovable:${CHAIN_REASON}"
elif [[ "${caller_account}" == "${expected_account}" ]]; then
  match_status="match"
  match_reason="post-phase-identity-equals-reference"
else
  match_status="mismatch"
  match_reason="post-phase-identity-differs-from-reference"
fi
unset caller_account expected_account role_arn

jq -n \
  --slurpfile context "${CONTEXT_FILE}" \
  --arg observed_at "${COMPARISON_OBSERVED_AT}" \
  --arg match_status "${match_status}" \
  --arg match_reason "${match_reason}" \
  --arg reference_source "${reference_source}" \
  --arg reference_status "${reference_status}" \
  --arg caller_status "${caller_status}" \
  '{
     schema_version: 1,
     producer: "rosa-aws-hcp-diagnose-aws-identity",
     test_context: $context[0],
     account_match: {
       status: $match_status,
       reason: $match_reason,
       expected_account_reference_source: $reference_source,
       expected_account_reference_status: $reference_status,
       caller_identity_status: $caller_status,
       comparison_observed_at: $observed_at,
       caller_identity_provenance: "post-phase-step: sts:GetCallerIdentity with the cluster profile credential file, read at comparison_observed_at",
       is_observation_of_test_time_caller: false,
       note: "this comparison was not observed at the time of the original AWS call; it is reported as unknown unless the conformance step proved the test process would use the same credential file"
     }
   }' > "${OUT_DIR}/identity-check.json"

{
  echo "AWS identity check (post phase, best effort)"
  echo "  comparison_observed_at:      ${COMPARISON_OBSERVED_AT}"
  echo "  account_match.status:        ${match_status}"
  echo "  account_match.reason:        ${match_reason}"
  echo "  expected reference source:   ${reference_source} (${reference_status})"
  echo "  caller identity status:      ${caller_status}"
  echo "  test credential chain proven:${CHAIN_PROVABLE}"
  echo "  region consistency:          $(jq -r '.region_consistency.status // "unknown"' "${CONTEXT_FILE}")"
  echo "  AWS API errors captured:     $(jq -r '.aws_api_error_count // 0' "${CONTEXT_FILE}")"
  echo
  echo "Account IDs and ARNs are intentionally absent from this report."
} | tee "${OUT_DIR}/identity-check.txt"

exit 0
