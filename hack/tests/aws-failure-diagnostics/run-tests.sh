#!/bin/bash

# Tests for the AWS failure diagnostics capture.
#
# The capture helper ships inside the inline `commands` block of
# hypershift-conformance-chain.yaml, so these tests extract the shipped text
# with extract.py and exercise that, rather than a copy that could drift. The
# post-phase step is a normal commands file and is executed directly with a
# stub `aws` on PATH: no cloud call is ever made.
#
# Usage: hack/tests/aws-failure-diagnostics/run-tests.sh

set -o nounset
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
CHAIN="${REPO}/ci-operator/step-registry/hypershift/conformance/hypershift-conformance-chain.yaml"
WORKFLOW="${REPO}/ci-operator/step-registry/rosa/aws/hcp/conformance/rosa-aws-hcp-conformance-workflow.yaml"
STEP_DIR="${REPO}/ci-operator/step-registry/rosa/aws/hcp/diagnose-aws-identity"
POST_STEP="${STEP_DIR}/rosa-aws-hcp-diagnose-aws-identity-commands.sh"
CONFIG="${REPO}/ci-operator/config/openshift/release/openshift-release-main__nightly-5.0.yaml"
FIXTURES="${HERE}/fixtures"

SENTINELS=(
  "sentinel-system-out-secret"
  "sentinel-failure-secret"
  "AKIAIOSFODNN7EXAMPLE"
  "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"
  "123456789012"
  "210987654321"
  "arn:aws:iam::"
  "hunter2"
  "eyJhbGciOiJSUzI1NiIs"
  "ip-10-0-107-53"
  "compute.internal"
)

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

check_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "${want}" == "${got}" ]]; then pass "${name}"; else fail "${name}" "want=${want} got=${got}"; fi
}

check_contains() {
  local name="$1" needle="$2" hay="$3"
  if [[ "${hay}" == *"${needle}"* ]]; then pass "${name}"; else fail "${name}" "missing ${needle}"; fi
}

check_no_sentinels() {
  local name="$1" file="$2" sentinel
  for sentinel in "${SENTINELS[@]}"; do
    if grep -qF -- "${sentinel}" "${file}" 2>/dev/null; then
      fail "${name}" "sentinel ${sentinel} leaked into ${file}"
      return
    fi
  done
  pass "${name}"
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PROGRAM="${WORK}/capture.py"
python3 -I "${HERE}/extract.py" "${CHAIN}" program > "${PROGRAM}" || exit 1
python3 -I "${HERE}/extract.py" "${CHAIN}" function > "${WORK}/function.sh" || exit 1
python3 -I "${HERE}/extract.py" "${CHAIN}" gate > "${WORK}/gate.sh" || exit 1

##############################################################################
# Shipped-text sanity
##############################################################################

if python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${PROGRAM}"; then
  pass "extracted capture program parses as python"
else
  fail "extracted capture program parses as python"
fi

if bash -n "${WORK}/function.sh"; then
  pass "extracted capture function parses as bash"
else
  fail "extracted capture function parses as bash"
fi

##############################################################################
# Static invariants of the chain wiring
##############################################################################

gate="$(cat "${WORK}/gate.sh")"
check_contains "gate is off unless AWS_FAILURE_DIAGNOSTICS is true" \
  '"${AWS_FAILURE_DIAGNOSTICS:-false}" == "true"' "${gate}"
check_contains "gate only runs on a failing suite" '"${exit_code}" -ne 0' "${gate}"
check_contains "gate disables xtrace around the capture" 'set +x' "${gate}"
check_contains "gate restores the previous xtrace state" \
  '[[ $- == *x* ]] && AWS_FAILURE_DIAGNOSTICS_WAS_TRACING=true' "${gate}"
check_contains "gate swallows capture failures" 'aws_failure_diagnostics_capture "${exit_code}" || true' "${gate}"
check_eq "gate ends by re-exiting the original code" 'exit ${exit_code}' \
  "$(tail -n 1 "${WORK}/gate.sh")"
check_eq "gate never reassigns exit_code" "0" \
  "$(grep -c '^[[:space:]]*exit_code=' "${WORK}/gate.sh")"

check_eq "chain declares the gate env defaulting to false" "1" \
  "$(grep -A1 'name: AWS_FAILURE_DIAGNOSTICS' "${CHAIN}" | grep -c 'default: "false"')"
check_eq "capture function is bounded by timeout" "3" \
  "$(grep -c 'timeout [0-9]' "${WORK}/function.sh")"

check_eq "post step is wired first and best effort" "1" \
  "$(grep -A1 'ref: rosa-aws-hcp-diagnose-aws-identity' "${WORKFLOW}" | grep -c 'best_effort: true')"
check_eq "only the 5.0 rosa hcp job enables the capture" "1" \
  "$(grep -c 'AWS_FAILURE_DIAGNOSTICS: "true"' "${CONFIG}")"
check_eq "no other config enables the capture" "1" \
  "$(grep -rl 'AWS_FAILURE_DIAGNOSTICS: "true"' "${REPO}/ci-operator/config" | wc -l | tr -d ' ')"
check_eq "capture never forces a region for the test" "0" \
  "$(grep -cE '^[[:space:]]*export (AWS_REGION|AWS_DEFAULT_REGION)=' "${WORK}/function.sh")"

##############################################################################
# Capture program behaviour
##############################################################################

NODES="${WORK}/nodes.txt"
cat > "${NODES}" <<'EOF'
ip-10-0-107-53.us-west-2.compute.internal aws:///us-west-2a/i-027aae04cdd9c7837
ip-10-0-14-9.us-west-2.compute.internal aws:///us-west-2b/i-0bf1b2c3d4e5f6071
EOF
INFRA="${WORK}/infra.txt"
printf 'us-west-2' > "${INFRA}"
CLUSTER_CONFIG="${WORK}/cluster-config"
cat > "${CLUSTER_CONFIG}" <<'EOF'
{"name":"fixture","region":"us-west-2","aws":{"sts":{"role_arn":"arn:aws:iam::123456789012:role/Fixture-Installer-Role"}}}
EOF

# Happy path: a diverging lease region, a provable credential chain.
OUT="${WORK}/context-happy.json"
env -u AWS_REGION -u AWS_DEFAULT_REGION -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
  -u AWS_SESSION_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
  -u AWS_WEB_IDENTITY_TOKEN_FILE -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
  -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  LEASED_RESOURCE="us-east-2--rosa-e2e-01-quota-slice-0" \
  CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" \
    --junit-dir "${FIXTURES}/junit-aws-errors" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" \
    --test-exit-code 1 --test-started-at "2026-11-06T04:04:32Z" \
    --test-ended-at "2026-11-06T05:30:00Z" --captured-at "2026-11-06T05:30:01Z" \
    --output "${OUT}"

check_eq "captures every AWS API error and nothing else" "4" "$(jq -r '.aws_api_error_count' "${OUT}")"
check_eq "captures the original request IDs" \
  "34c5f203-7490-4304-bfbd-b7be20abaf1f 8139035b-902f-4bb2-80d9-b80a73e3438b ccd6a6f2-c4b8-4410-8b3f-9a9466e61e30" \
  "$(jq -r '[.aws_api_errors[].request_id | select(. != null)] | sort | join(" ")' "${OUT}")"
check_eq "drops a key-like request id" "1" \
  "$(jq -r '[.aws_api_errors[] | select(.request_id == null and .error_code == "UnauthorizedOperation")] | length' "${OUT}")"
check_eq "captures the AWS error code" "InvalidInstanceID.NotFound" \
  "$(jq -r '.aws_api_errors[0].error_code' "${OUT}")"
check_eq "captures the HTTP status" "400" "$(jq -r '.aws_api_errors[0].http_status' "${OUT}")"
check_eq "captures the service and operation" "EC2 DescribeInstances" \
  "$(jq -r '.aws_api_errors[0] | "\(.service) \(.operation)"' "${OUT}")"
check_eq "captures the failing instance id" "i-027aae04cdd9c7837" \
  "$(jq -r '.aws_api_errors[0].instance_id' "${OUT}")"
check_eq "captures the per-test timestamp" "2026-11-06T05:19:07Z" \
  "$(jq -r '.aws_api_errors[0].test_started_at' "${OUT}")"
check_eq "rejects a malformed per-test timestamp" "null" \
  "$(jq -r '[.aws_api_errors[] | select(.request_id == "34c5f203-7490-4304-bfbd-b7be20abaf1f")][0].test_ended_at' "${OUT}")"
check_eq "reduces test names to an enum" \
  "cloud-provider-aws-nlb-byo-sg cloud-provider-aws-nlb-sg-transition cloud-provider-aws-other" \
  "$(jq -r '[.aws_api_errors[].test_class] | unique | sort_by(. == "cloud-provider-aws-other") | join(" ")' "${OUT}")"
check_eq "emits a stable truncated test digest" "12" \
  "$(jq -r '.aws_api_errors[0].test_digest | length' "${OUT}")"
check_eq "captures node providerIDs" "2" "$(jq -r '.node_count' "${OUT}")"
check_eq "parses the node instance id and zone" "i-027aae04cdd9c7837 us-west-2a us-west-2" \
  "$(jq -r '.nodes[0] | "\(.instance_id) \(.availability_zone) \(.region)"' "${OUT}")"
check_eq "the node hostname is reduced to a digest" "12" \
  "$(jq -r '.nodes[0].name_digest | length' "${OUT}")"
check_eq "the raw node hostname is not a field at all" "false" \
  "$(jq -r '.nodes[0] | has("name")' "${OUT}")"
check_eq "no node hostname appears anywhere in the document" "0" \
  "$(grep -cF -e 'ip-10-0-107-53' -e 'compute.internal' "${OUT}" || true)"
check_eq "records only the region component of the lease" "us-east-2" \
  "$(jq -r '.region_evidence.configured.lease_region.value' "${OUT}")"
check_eq "records the observed infrastructure region" "us-west-2" \
  "$(jq -r '.region_evidence.observed.infrastructure_region.value' "${OUT}")"
check_eq "records unset region env as a status" "unset" \
  "$(jq -r '.region_evidence.observed.aws_region_env.status' "${OUT}")"
check_eq "never claims the region the test process used" "unknown" \
  "$(jq -r '.region_evidence.test_process_resolved_region.status' "${OUT}")"
check_eq "flags diverging region inputs" "divergent" "$(jq -r '.region_consistency.status' "${OUT}")"
check_eq "proves the credential chain when only the profile file is set" "true" \
  "$(jq -r '.credential_context.effective_credential_chain_provable' "${OUT}")"
check_eq "preserves the suite exit code in the document" "1" "$(jq -r '.suite_exit_code' "${OUT}")"
check_no_sentinels "no sentinel reaches the capture document" "${OUT}"

# Region inputs that agree with the cluster.
OUT_MATCH="${WORK}/context-regions-match.json"
env -u AWS_DEFAULT_REGION -u AWS_ACCESS_KEY_ID \
  LEASED_RESOURCE="us-west-2--rosa-e2e-01-quota-slice-0" AWS_REGION="us-west-2" \
  CLUSTER_PROFILE_DIR="/secrets/profile" AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-aws-errors" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_MATCH}"
check_eq "agreeing region inputs are reported as such" "all-match" \
  "$(jq -r '.region_consistency.status' "${OUT_MATCH}")"
check_eq "observed region env is recorded" "us-west-2" \
  "$(jq -r '.region_evidence.observed.aws_region_env.value' "${OUT_MATCH}")"

# A non-region value in AWS_REGION must never be echoed.
OUT_BADENV="${WORK}/context-badenv.json"
env LEASED_RESOURCE="not-a-lease" AWS_REGION="sentinel-failure-secret" \
  AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE" \
  CLUSTER_PROFILE_DIR="/secrets/profile" AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-aws-errors" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_BADENV}"
check_eq "a non-region env value is reduced to a status" "set-not-a-region" \
  "$(jq -r '.region_evidence.observed.aws_region_env.status' "${OUT_BADENV}")"
check_eq "a lease without a region component is reported as such" "set-no-region-component" \
  "$(jq -r '.region_evidence.configured.lease_region.status' "${OUT_BADENV}")"
check_eq "an env credential override makes the chain unprovable" "false" \
  "$(jq -r '.credential_context.effective_credential_chain_provable' "${OUT_BADENV}")"
check_eq "the unprovable reason is recorded" "higher-precedence-credential-source-present" \
  "$(jq -r '.credential_context.unprovable_reason' "${OUT_BADENV}")"
check_no_sentinels "no sentinel reaches the document from the environment" "${OUT_BADENV}"

# A credentials file outside the cluster profile is also unprovable.
OUT_OTHERCRED="${WORK}/context-othercred.json"
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_WEB_IDENTITY_TOKEN_FILE \
  -u AWS_CONTAINER_CREDENTIALS_FULL_URI -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  LEASED_RESOURCE="us-west-2--x-0" \
  CLUSTER_PROFILE_DIR="/secrets/profile" AWS_SHARED_CREDENTIALS_FILE="/tmp/other/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-aws-errors" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_OTHERCRED}"
check_eq "a foreign credentials file makes the chain unprovable" \
  "shared-credentials-file-not-cluster-profile" \
  "$(jq -r '.credential_context.unprovable_reason' "${OUT_OTHERCRED}")"

# A polluted but benign AWS environment must be reported, not papered over: the
# production code reads these variables deliberately, because they outrank the
# shared credentials file in the SDK chain.
#
# These two cases assert exactly which credential source the capture saw, so
# they are run with env -i: an inherited variable would either contradict the
# assertion outright or, worse, satisfy "unprovable" for an unrelated reason and
# mask a regression in detecting the source under test. That is not
# hypothetical, because a CI pod can itself export
# AWS_CONTAINER_CREDENTIALS_FULL_URI.
run_capture_isolated() {
  # run_capture_isolated <output> [EXTRA_VAR=VALUE ...]
  local output="$1"
  shift
  env -i PATH="${PATH}" HOME="${WORK}" \
    LEASED_RESOURCE="us-west-2--x-0" \
    CLUSTER_PROFILE_DIR="/secrets/profile" \
    AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
    "$@" \
    python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-aws-errors" --nodes-file "${NODES}" \
      --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
      --captured-at "2026-11-06T05:30:01Z" --output "${output}"
}

OUT_POLLUTED="${WORK}/context-polluted-env.json"
run_capture_isolated "${OUT_POLLUTED}" AWS_SESSION_TOKEN="synthetic-session-token-for-tests"
check_eq "an inherited session token makes the chain unprovable" "false" \
  "$(jq -r '.credential_context.effective_credential_chain_provable' "${OUT_POLLUTED}")"
check_eq "the inherited source is named, not hidden" "higher-precedence-credential-source-present" \
  "$(jq -r '.credential_context.unprovable_reason' "${OUT_POLLUTED}")"
check_eq "the session token alone is reported as a boolean" "true false" \
  "$(jq -r '"\(.credential_context.aws_session_token_env_present) \(.credential_context.aws_profile_env_present)"' "${OUT_POLLUTED}")"
check_eq "the session token case sees no other credential source" "false false false false" \
  "$(jq -r '.credential_context | "\(.aws_container_credentials_env_present) \(.aws_access_key_id_env_present) \(.aws_secret_access_key_env_present) \(.aws_web_identity_token_file_env_present)"' "${OUT_POLLUTED}")"
check_eq "no inherited credential value is echoed" "0" \
  "$(grep -cF 'synthetic-session-token-for-tests' "${OUT_POLLUTED}" || true)"

# The same, with only AWS_PROFILE set, so neither variable can hide a
# regression in the detection of the other.
OUT_POLLUTED_PROFILE="${WORK}/context-polluted-profile.json"
run_capture_isolated "${OUT_POLLUTED_PROFILE}" AWS_PROFILE="synthetic-profile"
check_eq "an inherited profile alone makes the chain unprovable" "false" \
  "$(jq -r '.credential_context.effective_credential_chain_provable' "${OUT_POLLUTED_PROFILE}")"
check_eq "the inherited profile is reported as a boolean" "false true" \
  "$(jq -r '"\(.credential_context.aws_session_token_env_present) \(.credential_context.aws_profile_env_present)"' "${OUT_POLLUTED_PROFILE}")"
check_eq "the profile case sees no other credential source" "false false false false" \
  "$(jq -r '.credential_context | "\(.aws_container_credentials_env_present) \(.aws_access_key_id_env_present) \(.aws_secret_access_key_env_present) \(.aws_web_identity_token_file_env_present)"' "${OUT_POLLUTED_PROFILE}")"
check_eq "no inherited profile value is echoed" "0" \
  "$(grep -cF 'synthetic-profile' "${OUT_POLLUTED_PROFILE}" || true)"

# Regression for the isolation itself: re-run both cases with deliberately
# conflicting benign synthetic AWS variables exported by the caller, and require
# the same credential context. Each case is pinned against literal flags first,
# so a capture that failed to run cannot make the comparison pass by leaving two
# empty strings. The subshell keeps the pollution off the rest of the suite; the
# assertions run outside it so the counters survive.
OUT_IMMUNE_TOKEN="${WORK}/context-immune-token.json"
OUT_IMMUNE_PROFILE="${WORK}/context-immune-profile.json"
(
  export AWS_PROFILE="conflicting-synthetic-profile"
  export AWS_DEFAULT_PROFILE="conflicting-synthetic-default-profile"
  export AWS_SESSION_TOKEN="conflicting-synthetic-session-token"
  export AWS_ACCESS_KEY_ID="conflicting-synthetic-key-id"
  export AWS_SECRET_ACCESS_KEY="conflicting-synthetic-secret"
  export AWS_WEB_IDENTITY_TOKEN_FILE="/tmp/conflicting-synthetic-token-file"
  export AWS_CONTAINER_CREDENTIALS_FULL_URI="http://127.0.0.1:1/conflicting-synthetic"
  run_capture_isolated "${OUT_IMMUNE_TOKEN}" AWS_SESSION_TOKEN="synthetic-session-token-for-tests"
  run_capture_isolated "${OUT_IMMUNE_PROFILE}" AWS_PROFILE="synthetic-profile"
)
OVERRIDE_FLAGS='.credential_context | "\(.aws_session_token_env_present) \(.aws_profile_env_present) \(.aws_access_key_id_env_present) \(.aws_secret_access_key_env_present) \(.aws_web_identity_token_file_env_present) \(.aws_container_credentials_env_present)"'
check_eq "the session token case keeps its flags under a conflicting caller environment" \
  "true false false false false false" "$(jq -r "${OVERRIDE_FLAGS}" "${OUT_IMMUNE_TOKEN}")"
check_eq "the profile case keeps its flags under a conflicting caller environment" \
  "false true false false false false" "$(jq -r "${OVERRIDE_FLAGS}" "${OUT_IMMUNE_PROFILE}")"
check_eq "the session token case is immune to a conflicting caller environment" \
  "$(jq -S -c '.credential_context' "${OUT_POLLUTED}")" \
  "$(jq -S -c '.credential_context' "${OUT_IMMUNE_TOKEN}")"
check_eq "the profile case is immune to a conflicting caller environment" \
  "$(jq -S -c '.credential_context' "${OUT_POLLUTED_PROFILE}")" \
  "$(jq -S -c '.credential_context' "${OUT_IMMUNE_PROFILE}")"
check_eq "no conflicting caller value is echoed" "0" \
  "$(cat "${OUT_IMMUNE_TOKEN}" "${OUT_IMMUNE_PROFILE}" | grep -cF 'conflicting-synthetic' || true)"

# Malformed XML: the broken file is noted, the good file is still parsed.
OUT_MALFORMED="${WORK}/context-malformed.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-malformed" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_MALFORMED}"
check_eq "a malformed junit file is noted" "true" \
  "$(jq -r '.capture_notes | index("junit-parse-error") != null' "${OUT_MALFORMED}")"
check_eq "a malformed junit file does not hide the good one" "4" \
  "$(jq -r '.aws_api_error_count' "${OUT_MALFORMED}")"
check_eq "a partial capture is labelled partial" "partial" \
  "$(jq -r '.capture_status' "${OUT_MALFORMED}")"

# No junit at all, no nodes, no cluster config.
OUT_EMPTY="${WORK}/context-empty.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${WORK}/absent" --nodes-file "${WORK}/absent" \
    --infra-region-file "${WORK}/absent" --cluster-config "${WORK}/absent" --test-exit-code 0 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_EMPTY}"
check_eq "missing sources yield zero errors, not a guess" "0" \
  "$(jq -r '.aws_api_error_count' "${OUT_EMPTY}")"
check_eq "missing sources are enumerated" "true" \
  "$(jq -r '[.capture_notes[] | select(. == "junit-dir-unreadable" or . == "nodes-unavailable" or . == "cluster-config-unreadable")] | length == 3' "${OUT_EMPTY}")"
check_eq "region consistency is unknown without a cluster region" "unknown" \
  "$(jq -r '.region_consistency.status' "${OUT_EMPTY}")"

# Credential-shaped values must be dropped wherever they appear.
OUT_CRED="${WORK}/context-credential-shaped.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-credential-shaped" \
    --nodes-file "${NODES}" --infra-region-file "${INFRA}" \
    --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_CRED}"
check_eq "a key-like AWS error code is dropped" "null" \
  "$(jq -r '.aws_api_errors[0].error_code' "${OUT_CRED}")"
check_eq "a secret-shaped request id is dropped" "null" \
  "$(jq -r '.aws_api_errors[1].request_id' "${OUT_CRED}")"
check_eq "the surrounding allowlisted fields survive" "EC2 DescribeInstances 403" \
  "$(jq -r '.aws_api_errors[0] | "\(.service) \(.operation) \(.http_status)"' "${OUT_CRED}")"
check_no_sentinels "no credential-shaped value reaches the document" "${OUT_CRED}"

# Fields whose value the suite under test controls must not accept prose or an
# opaque token, whichever position it is offered in.
OUT_LEAK="${WORK}/context-leak-attempts.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-leak-attempts" \
    --nodes-file "${NODES}" --infra-region-file "${INFRA}" \
    --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_LEAK}"
check_eq "all four leak attempts are still recorded as errors" "4" \
  "$(jq -r '.aws_api_error_count' "${OUT_LEAK}")"
check_eq "a secret-shaped error code is dropped" "null" \
  "$(jq -r '.aws_api_errors[0].error_code' "${OUT_LEAK}")"
check_eq "prose in the service position is dropped" "null" \
  "$(jq -r '.aws_api_errors[1].service' "${OUT_LEAK}")"
check_eq "the operation beside dropped prose survives" "DescribeInstances" \
  "$(jq -r '.aws_api_errors[1].operation' "${OUT_LEAK}")"
check_eq "a bare account id in the request id position is dropped" "null" \
  "$(jq -r '.aws_api_errors[2].request_id' "${OUT_LEAK}")"
check_eq "a JWT in the error code position is dropped" "null" \
  "$(jq -r '.aws_api_errors[3].error_code' "${OUT_LEAK}")"
check_no_sentinels "no leak attempt reaches the document" "${OUT_LEAK}"

# XML entity escapes must be decoded, not pattern-matched around.
OUT_ESC="${WORK}/context-escapes.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-entity-escapes" \
    --nodes-file "${NODES}" --infra-region-file "${INFRA}" \
    --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_ESC}"
check_eq "a numerically escaped HTTP status is decoded" "400" \
  "$(jq -r '.aws_api_errors[0].http_status' "${OUT_ESC}")"
check_eq "a numerically escaped error code is decoded" "InvalidInstanceID.NotFound" \
  "$(jq -r '.aws_api_errors[0].error_code' "${OUT_ESC}")"
check_eq "an apostrophe-escaped instance id is decoded" "i-027aae04cdd9c7837" \
  "$(jq -r '.aws_api_errors[0].instance_id' "${OUT_ESC}")"

# A DTD is refused outright, which removes entity expansion as a concern.
OUT_DTD="${WORK}/context-doctype.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-doctype" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_DTD}"
check_eq "a junit file declaring a DTD is refused" "true" \
  "$(jq -r '.capture_notes | index("junit-doctype-rejected") != null' "${OUT_DTD}")"
check_eq "a refused junit file yields no errors" "0" \
  "$(jq -r '.aws_api_error_count' "${OUT_DTD}")"

# A DTD hidden behind padding is refused too: the whole file is scanned.
OUT_DTD_PAD="${WORK}/context-doctype-padded.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${FIXTURES}/junit-doctype-padded" \
    --nodes-file "${NODES}" --infra-region-file "${INFRA}" \
    --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_DTD_PAD}"
check_eq "a DTD behind padding is still refused" "true" \
  "$(jq -r '.capture_notes | index("junit-doctype-rejected") != null' "${OUT_DTD_PAD}")"
check_eq "a padded DTD file yields no errors" "0" \
  "$(jq -r '.aws_api_error_count' "${OUT_DTD_PAD}")"

# A DTD that straddles the scanner's chunk boundary exercises the carry.
STRADDLE="${WORK}/junit-straddle"
mkdir -p "${STRADDLE}"
python3 -I - "${STRADDLE}/junit_straddle.xml" "${PROGRAM}" <<'PYEOF'
import re
import sys


def constant(source, name):
    """Read an integer constant out of the shipped capture program."""
    match = re.search(r"^\s*%s = ([0-9 *+]+)$" % name, source, re.MULTILINE)
    assert match, "constant %s not found in the capture program" % name
    return eval(match.group(1))  # pylint: disable=eval-used


program = open(sys.argv[2], encoding="utf-8").read()
boundary = constant(program, "SCAN_CHUNK_BYTES")
overlap = constant(program, "SCAN_OVERLAP_BYTES")

HEAD = b'<?xml version="1.0"?>\n<!--'
# No internal subset: "<!ENTITY" would land wholly inside the second chunk and
# would trip the scan on its own, which would let a carry regression pass.
TAIL = b'-->\n<!DOCTYPE testsuite SYSTEM "x.dtd">\n<testsuite name="openshift-tests"/>\n'
assert b"<!ENTITY" not in HEAD + TAIL
# Split "<!DOCTYPE" across the boundary, leaving four bytes in the first chunk.
split_at = 4
assert overlap >= len(b"<!DOCTYPE"), overlap
pad = boundary - split_at - len(HEAD) - len(b"-->\n")
data = HEAD + b"x" * pad + TAIL
assert data.index(b"<!DOCTYPE") == boundary - split_at, data.index(b"<!DOCTYPE")
with open(sys.argv[1], "wb") as handle:
    handle.write(data)
PYEOF
OUT_STRADDLE="${WORK}/context-doctype-straddle.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${STRADDLE}" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_STRADDLE}"
check_eq "a DTD straddling the scan chunk boundary is refused" "true" \
  "$(jq -r '.capture_notes | index("junit-doctype-rejected") != null' "${OUT_STRADDLE}")"
check_eq "a straddling DTD file yields no errors" "0" \
  "$(jq -r '.aws_api_error_count' "${OUT_STRADDLE}")"

# Many junit files: the suite results are scanned first and the bound is noted.
MANY="${WORK}/junit-many"
mkdir -p "${MANY}"
for index in $(seq -w 1 30); do
  printf '<testsuite name="monitor"><testcase name="m%s"/></testsuite>\n' "${index}" \
    > "${MANY}/e2e-monitor-${index}.xml"
done
cp "${FIXTURES}/junit-aws-errors/junit_e2e__fixture.xml" "${MANY}/"
OUT_MANY="${WORK}/context-many.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${MANY}" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_MANY}"
check_eq "the suite results are scanned despite the file bound" "4" \
  "$(jq -r '.aws_api_error_count' "${OUT_MANY}")"
check_eq "dropping files past the bound is recorded" "true" \
  "$(jq -r '.capture_notes | index("junit-files-truncated") != null' "${OUT_MANY}")"

# An oversized junit file is refused before it is parsed.
HUGE="${WORK}/junit-huge"
mkdir -p "${HUGE}"
truncate -s 65M "${HUGE}/junit_huge.xml"
OUT_HUGE="${WORK}/context-huge.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${HUGE}" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_HUGE}"
check_eq "an oversized junit file is refused" "true" \
  "$(jq -r '.capture_notes | index("junit-file-too-large") != null' "${OUT_HUGE}")"

# Bounded: many AWS failures are truncated.
BIG="${WORK}/junit-big"
mkdir -p "${BIG}"
python3 -I - "${BIG}/junit_big.xml" <<'PYEOF'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write('<testsuite name="openshift-tests">\n')
    for index in range(40):
        handle.write(
            '  <testcase name="[cloud-provider-aws-e2e] case %d">'
            '<failure>operation error EC2: DescribeInstances, '
            'https response error StatusCode: 400, RequestID: '
            '00000000-0000-0000-0000-%012d, api error Throttling: slow</failure>'
            '</testcase>\n' % (index, index)
        )
    handle.write("</testsuite>\n")
PYEOF
OUT_BIG="${WORK}/context-big.json"
env LEASED_RESOURCE="us-west-2--x-0" CLUSTER_PROFILE_DIR="/secrets/profile" \
  AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
  python3 -I "${PROGRAM}" --junit-dir "${BIG}" --nodes-file "${NODES}" \
    --infra-region-file "${INFRA}" --cluster-config "${CLUSTER_CONFIG}" --test-exit-code 1 \
    --captured-at "2026-11-06T05:30:01Z" --output "${OUT_BIG}"
check_eq "the error list is bounded" "25" "$(jq -r '.aws_api_error_count' "${OUT_BIG}")"
check_eq "truncation is recorded" "true" \
  "$(jq -r '.capture_notes | index("aws-api-errors-truncated") != null' "${OUT_BIG}")"

##############################################################################
# Capture function and gate, executed as shipped
##############################################################################

STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
cat > "${STUBS}/oc" <<EOF
#!/bin/bash
case "\$*" in
  *"get nodes"*) cat "${NODES}" ;;
  *infrastructure*) printf 'us-west-2' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${STUBS}/oc"

run_gate() {
  # run_gate <AWS_FAILURE_DIAGNOSTICS> <exit_code> <artifact_dir> <shared_dir>
  local gate_value="$1" code="$2" artifact_dir="$3" shared_dir="$4"
  local script="${WORK}/gate-harness.sh"
  {
    echo 'set -x'
    cat "${WORK}/function.sh"
    echo "exit_code=${code}"
    cat "${WORK}/gate.sh"
  } > "${script}"
  mkdir -p "${artifact_dir}/junit" "${shared_dir}"
  cp "${FIXTURES}/junit-aws-errors/"*.xml "${artifact_dir}/junit/"
  cp "${CLUSTER_CONFIG}" "${shared_dir}/cluster-config"
  env -i PATH="${STUBS}:${PATH}" HOME="${WORK}" \
    AWS_FAILURE_DIAGNOSTICS="${gate_value}" \
    ARTIFACT_DIR="${artifact_dir}" SHARED_DIR="${shared_dir}" \
    CLUSTER_PROFILE_DIR="/secrets/profile" \
    AWS_SHARED_CREDENTIALS_FILE="/secrets/profile/.awscred" \
    LEASED_RESOURCE="us-east-2--rosa-e2e-01-quota-slice-0" \
    bash "${script}" > "${artifact_dir}/stdout.txt" 2> "${artifact_dir}/stderr.txt"
  echo "$?"
}

ART_ON="${WORK}/run-on/artifacts"; SHARED_ON="${WORK}/run-on/shared"
status="$(run_gate true 7 "${ART_ON}" "${SHARED_ON}")"
check_eq "the original failing exit status is preserved" "7" "${status}"
if [[ -s "${ART_ON}/aws-failure-diagnostics/test-context.json" ]]; then
  pass "the capture writes an artifact document"
else
  fail "the capture writes an artifact document"
fi
if [[ -s "${SHARED_ON}/aws-failure-diagnostics-test-context.json" ]]; then
  pass "the capture hands the document to SHARED_DIR"
else
  fail "the capture hands the document to SHARED_DIR"
fi
check_eq "the document reaching SHARED_DIR carries the request IDs" "3" \
  "$(jq -r '[.aws_api_errors[].request_id | select(. != null)] | length' "${SHARED_ON}/aws-failure-diagnostics-test-context.json" 2>/dev/null)"
check_no_sentinels "no sentinel reaches the capture stdout" "${ART_ON}/stdout.txt"
check_no_sentinels "no sentinel reaches the capture stderr" "${ART_ON}/stderr.txt"
check_eq "the capture is not traced by xtrace" "0" \
  "$(grep -c 'capture.py' "${ART_ON}/stderr.txt")"

ART_OFF="${WORK}/run-off/artifacts"; SHARED_OFF="${WORK}/run-off/shared"
status="$(run_gate false 7 "${ART_OFF}" "${SHARED_OFF}")"
check_eq "the gate-disabled path preserves the exit status" "7" "${status}"
if [[ -e "${ART_OFF}/aws-failure-diagnostics" ]]; then
  fail "the gate-disabled path writes nothing"
else
  pass "the gate-disabled path writes nothing"
fi

ART_PASS="${WORK}/run-pass/artifacts"; SHARED_PASS="${WORK}/run-pass/shared"
status="$(run_gate true 0 "${ART_PASS}" "${SHARED_PASS}")"
check_eq "a passing suite still exits zero" "0" "${status}"
if [[ -e "${ART_PASS}/aws-failure-diagnostics" ]]; then
  fail "a passing suite is not captured"
else
  pass "a passing suite is not captured"
fi

# oc unavailable: the capture must stay best effort.
BROKEN="${WORK}/broken-stubs"; mkdir -p "${BROKEN}"
printf '#!/bin/bash\nexit 1\n' > "${BROKEN}/oc"; chmod +x "${BROKEN}/oc"
ART_NOOC="${WORK}/run-nooc/artifacts"; SHARED_NOOC="${WORK}/run-nooc/shared"
mkdir -p "${ART_NOOC}/junit" "${SHARED_NOOC}"
cp "${FIXTURES}/junit-aws-errors/"*.xml "${ART_NOOC}/junit/"
{
  echo 'set -x'
  cat "${WORK}/function.sh"
  echo 'exit_code=3'
  cat "${WORK}/gate.sh"
} > "${WORK}/nooc.sh"
env -i PATH="${BROKEN}:${PATH}" HOME="${WORK}" AWS_FAILURE_DIAGNOSTICS=true \
  ARTIFACT_DIR="${ART_NOOC}" SHARED_DIR="${SHARED_NOOC}" \
  bash "${WORK}/nooc.sh" >/dev/null 2>&1
check_eq "a failing oc does not change the exit status" "3" "$?"
check_eq "a failing oc still yields the AWS errors" "4" \
  "$(jq -r '.aws_api_error_count' "${ART_NOOC}/aws-failure-diagnostics/test-context.json" 2>/dev/null)"
check_eq "a failing oc is reported as unavailable nodes" "true" \
  "$(jq -r '.capture_notes | index("nodes-unavailable") != null' "${ART_NOOC}/aws-failure-diagnostics/test-context.json" 2>/dev/null)"

# The extractor itself failing must stay best effort.
BADPY="${WORK}/badpy-stubs"; mkdir -p "${BADPY}"
cp "${STUBS}/oc" "${BADPY}/oc"
printf '#!/bin/bash\nexit 1\n' > "${BADPY}/python3"; chmod +x "${BADPY}/python3"
ART_BADPY="${WORK}/run-badpy/artifacts"; SHARED_BADPY="${WORK}/run-badpy/shared"
mkdir -p "${ART_BADPY}/junit" "${SHARED_BADPY}"
cp "${FIXTURES}/junit-aws-errors/"*.xml "${ART_BADPY}/junit/"
{
  echo 'set -x'
  cat "${WORK}/function.sh"
  echo 'exit_code=42'
  cat "${WORK}/gate.sh"
} > "${WORK}/badpy.sh"
env -i PATH="${BADPY}:${PATH}" HOME="${WORK}" AWS_FAILURE_DIAGNOSTICS=true \
  ARTIFACT_DIR="${ART_BADPY}" SHARED_DIR="${SHARED_BADPY}" \
  bash "${WORK}/badpy.sh" > "${ART_BADPY}/stdout.txt" 2>"${ART_BADPY}/stderr.txt"
check_eq "a failing extractor does not change the exit status" "42" "$?"
check_contains "a failing extractor says so and continues" \
  "aws-failure-diagnostics: capture failed, continuing" "$(cat "${ART_BADPY}/stdout.txt")"
if [[ -s "${SHARED_BADPY}/aws-failure-diagnostics-test-context.json" ]]; then
  fail "a failing extractor hands nothing to the post step"
else
  pass "a failing extractor hands nothing to the post step"
fi
check_no_sentinels "a failing extractor leaks nothing to stderr" "${ART_BADPY}/stderr.txt"

##############################################################################
# Post-phase identity check
##############################################################################

make_aws_stub() {
  # make_aws_stub <dir> <account-or-FAIL>
  mkdir -p "$1"
  if [[ "$2" == "FAIL" ]]; then
    printf '#!/bin/bash\necho "stub: boom" >&2\nexit 255\n' > "$1/aws"
  else
    printf '#!/bin/bash\nprintf %%s\\\\n "%s"\n' "$2" > "$1/aws"
  fi
  chmod +x "$1/aws"
}

run_post() {
  # run_post <name> <caller-account|FAIL> <reference-mode> <chain-provable> [env-mode]
  local name="$1" caller="$2" reference="$3" provable="$4" env_mode="${5:-normal}"
  local root="${WORK}/post-${name}"
  local shared="${root}/shared" artifacts="${root}/artifacts" profile="${root}/profile"
  mkdir -p "${shared}" "${artifacts}" "${profile}" "${root}/bin"
  if [[ "${env_mode}" != "no-credential-file" ]]; then
    printf '[default]\naws_access_key_id = fixture\n' > "${profile}/.awscred"
  fi
  jq -n --argjson provable "${provable}" \
    '{credential_context:{effective_credential_chain_provable:$provable,
                          unprovable_reason:(if $provable then null else "higher-precedence-credential-source-present" end)},
      region_evidence:{configured:{cluster_config_region:{value:"us-west-2"}}},
      region_consistency:{status:"divergent"},
      aws_api_error_count:3}' \
    > "${shared}/aws-failure-diagnostics-test-context.json"
  case "${reference}" in
    roles) printf 'arn:aws:iam::123456789012:role/Fixture-Installer-Role\n' > "${shared}/account-roles-arns" ;;
    roles-shared-vpc)
      # The VPC-owner ARN comes first; the installer role must still win.
      printf 'arn:aws:iam::210987654321:role/Shared-VPC-Role\narn:aws:iam::123456789012:role/Fixture-Installer-Role\n' \
        > "${shared}/account-roles-arns" ;;
    cluster-config) printf '{"region":"us-west-2","aws":{"sts":{"role_arn":"arn:aws:iam::123456789012:role/Fixture-Installer-Role"}}}\n' > "${shared}/cluster-config" ;;
    malformed) printf 'this is not an arn\n' > "${shared}/account-roles-arns" ;;
    none) : ;;
  esac
  if [[ "${env_mode}" != "no-aws-cli" ]]; then
    make_aws_stub "${root}/bin" "${caller}"
  fi
  env -i PATH="${root}/bin:${PATH}" HOME="${root}" \
    SHARED_DIR="${shared}" ARTIFACT_DIR="${artifacts}" \
    CLUSTER_PROFILE_DIR="${profile}" REGION="us-west-2" \
    bash "${POST_STEP}" > "${root}/stdout.txt" 2> "${root}/stderr.txt"
  echo "$?" > "${root}/status"
  echo "${root}"
}

root="$(run_post match 123456789012 roles true)"
check_eq "post step exits zero" "0" "$(cat "${root}/status")"
check_eq "a matching account is reported as a match" "match" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the reference source is named" "shared-dir-account-roles-arns" \
  "$(jq -r '.account_match.expected_account_reference_source' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the comparison time is recorded" "true" \
  "$(jq -r '.account_match.comparison_observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the identity is not claimed as a test-time observation" "false" \
  "$(jq -r '.account_match.is_observation_of_test_time_caller' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the test context is carried through" "3" \
  "$(jq -r '.test_context.aws_api_error_count' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_no_sentinels "no account id reaches the identity artifact" \
  "${root}/artifacts/aws-failure-diagnostics/identity-check.json"
check_no_sentinels "no account id reaches the identity summary" \
  "${root}/artifacts/aws-failure-diagnostics/identity-check.txt"
check_no_sentinels "no account id reaches the post step stdout" "${root}/stdout.txt"
check_no_sentinels "no account id reaches the post step stderr" "${root}/stderr.txt"

root="$(run_post cluster-config 123456789012 cluster-config true)"
check_eq "the cluster-config role ARN is an accepted reference" "shared-dir-cluster-config-role-arn" \
  "$(jq -r '.account_match.expected_account_reference_source' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the cluster-config reference still matches" "match" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

root="$(run_post shared-vpc 123456789012 roles-shared-vpc true)"
check_eq "the installer role wins over a foreign ARN listed first" "match" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

root="$(run_post mismatch 210987654321 roles true)"
check_eq "a different account is reported as a mismatch" "mismatch" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_no_sentinels "a mismatch does not leak either account id" \
  "${root}/artifacts/aws-failure-diagnostics/identity-check.json"

root="$(run_post missing-reference 123456789012 none true)"
check_eq "a missing reference is unknown, not a match" "unknown" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the missing reference is explained" "expected-account-reference-missing" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

root="$(run_post malformed-reference 123456789012 malformed true)"
check_eq "a malformed reference is unknown, not a match" "unknown" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the malformed reference is explained" "expected-account-reference-malformed" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

root="$(run_post sts-failure FAIL roles true)"
check_eq "a failed STS read is unknown, not a match" "unknown" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the failed STS read is explained" "caller-identity-sts-call-failed" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the AWS CLI stderr is not propagated" "0" \
  "$(grep -c 'stub: boom' "${root}/stderr.txt" "${root}/stdout.txt" | awk -F: '{s+=$2} END {print s}')"

root="$(run_post malformed-identity not-an-account roles true)"
check_eq "a non-account STS response is unknown, not a match" "unknown" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the non-account response is explained" "caller-identity-malformed-response" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

root="$(run_post no-credential-file 123456789012 roles true no-credential-file)"
check_eq "an absent credential file is unknown, not a match" "caller-identity-credential-file-absent" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

root="$(run_post no-aws-cli 123456789012 roles true no-aws-cli)"
check_eq "an absent AWS CLI is unknown, not a match" "caller-identity-aws-cli-absent" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "an absent AWS CLI still exits zero" "0" "$(cat "${root}/status")"

root="$(run_post unprovable-chain 123456789012 roles false)"
check_eq "identical accounts are still unknown when the chain is unprovable" "unknown" \
  "$(jq -r '.account_match.status' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"
check_eq "the unprovable chain is explained" \
  "test-credential-chain-unprovable:higher-precedence-credential-source-present" \
  "$(jq -r '.account_match.reason' "${root}/artifacts/aws-failure-diagnostics/identity-check.json")"

# No context at all: a silent no-op, which is what every other workflow sees.
NOCTX="${WORK}/post-noctx"
mkdir -p "${NOCTX}/shared" "${NOCTX}/artifacts" "${NOCTX}/profile" "${NOCTX}/bin"
make_aws_stub "${NOCTX}/bin" 123456789012
env -i PATH="${NOCTX}/bin:${PATH}" HOME="${NOCTX}" SHARED_DIR="${NOCTX}/shared" \
  ARTIFACT_DIR="${NOCTX}/artifacts" CLUSTER_PROFILE_DIR="${NOCTX}/profile" \
  bash "${POST_STEP}" > "${NOCTX}/stdout.txt" 2>&1
check_eq "no context is a silent success" "0" "$?"
if [[ -e "${NOCTX}/artifacts/aws-failure-diagnostics" ]]; then
  fail "no context writes no artifact"
else
  pass "no context writes no artifact"
fi

# Malformed context JSON is tolerated.
BADCTX="${WORK}/post-badctx"
mkdir -p "${BADCTX}/shared" "${BADCTX}/artifacts" "${BADCTX}/profile" "${BADCTX}/bin"
printf 'not json' > "${BADCTX}/shared/aws-failure-diagnostics-test-context.json"
make_aws_stub "${BADCTX}/bin" 123456789012
env -i PATH="${BADCTX}/bin:${PATH}" HOME="${BADCTX}" SHARED_DIR="${BADCTX}/shared" \
  ARTIFACT_DIR="${BADCTX}/artifacts" CLUSTER_PROFILE_DIR="${BADCTX}/profile" \
  bash "${POST_STEP}" > "${BADCTX}/stdout.txt" 2>&1
check_eq "a malformed context is a tolerated no-op" "0" "$?"
if [[ -e "${BADCTX}/artifacts/aws-failure-diagnostics" ]]; then
  fail "a malformed context writes no artifact"
else
  pass "a malformed context writes no artifact"
fi

##############################################################################
# Shared-directory handoff, across the real transport semantics
#
# ci-operator does not share a filesystem between steps. At the end of a step
# the entrypoint wrapper persists ${SHARED_DIR} with util.SecretFromDir
# (openshift/ci-tools pkg/util/secret.go), which reads the directory one level
# deep and skips every entry that is a directory, then the next step receives
# that Secret mounted as its ${SHARED_DIR}. A file in a subdirectory is
# therefore dropped, with only a warning in the producing step's own log, and
# never reaches the next step. These tests reproduce that instead of handing
# the post step the producer's own directory, which would pass either way.
##############################################################################

simulate_shared_dir_transport() {
  # simulate_shared_dir_transport <producer-shared-dir> <consumer-shared-dir>
  # Mirrors util.SecretFromDir: top level only, regular files only.
  local src="$1" dst="$2" entry
  mkdir -p "${dst}"
  for entry in "${src}"/* "${src}"/.[!.]* "${src}"/..?*; do
    [[ -e "${entry}" ]] || continue
    if [[ -d "${entry}" ]]; then
      continue
    fi
    cp "${entry}" "${dst}/$(basename "${entry}")"
  done
}

run_handoff() {
  # run_handoff <name> <producer-shared-dir-writer>
  local name="$1" layout="$2"
  local root="${WORK}/handoff-${name}"
  local produced="${root}/produced" consumed="${root}/consumed"
  local artifacts="${root}/artifacts" post_artifacts="${root}/post-artifacts"
  local profile="${root}/profile" bin="${root}/bin"
  mkdir -p "${produced}" "${artifacts}/junit" "${post_artifacts}" "${profile}" "${bin}"
  cp "${FIXTURES}/junit-aws-errors/"*.xml "${artifacts}/junit/"
  printf '[default]\naws_access_key_id = fixture\n' > "${profile}/.awscred"
  # Written by the provisioning steps, at the top level of SHARED_DIR.
  printf 'arn:aws:iam::123456789012:role/Fixture-Installer-Role\n' > "${produced}/account-roles-arns"
  printf '{"region":"us-west-2"}\n' > "${produced}/cluster-config"

  if [[ "${layout}" == "nested" ]]; then
    # The layout this change originally shipped, kept as a negative control.
    mkdir -p "${produced}/aws-failure-diagnostics"
    printf '{"credential_context":{"effective_credential_chain_provable":true}}\n' \
      > "${produced}/aws-failure-diagnostics/test-context.json"
  else
    {
      echo 'set -x'
      cat "${WORK}/function.sh"
      echo 'exit_code=9'
      cat "${WORK}/gate.sh"
    } > "${root}/produce.sh"
    env -i PATH="${STUBS}:${PATH}" HOME="${root}" AWS_FAILURE_DIAGNOSTICS=true \
      ARTIFACT_DIR="${artifacts}" SHARED_DIR="${produced}" \
      CLUSTER_PROFILE_DIR="${profile}" \
      AWS_SHARED_CREDENTIALS_FILE="${profile}/.awscred" \
      LEASED_RESOURCE="us-east-2--rosa-e2e-01-quota-slice-0" \
      bash "${root}/produce.sh" > "${root}/produce-stdout.txt" 2> "${root}/produce-stderr.txt"
    echo "$?" > "${root}/produce-status"
  fi

  simulate_shared_dir_transport "${produced}" "${consumed}"

  make_aws_stub "${bin}" 123456789012
  env -i PATH="${bin}:${PATH}" HOME="${root}" \
    SHARED_DIR="${consumed}" ARTIFACT_DIR="${post_artifacts}" \
    CLUSTER_PROFILE_DIR="${profile}" REGION="us-west-2" \
    bash "${POST_STEP}" > "${root}/post-stdout.txt" 2> "${root}/post-stderr.txt"
  echo "$?" > "${root}/post-status"
  echo "${root}"
}

root="$(run_handoff flat flat)"
check_eq "the producing step still exits with the suite status" "9" \
  "$(cat "${root}/produce-status")"
if [[ -s "${root}/consumed/aws-failure-diagnostics-test-context.json" ]]; then
  pass "the handoff file survives the shared-directory transport"
else
  fail "the handoff file survives the shared-directory transport"
fi
check_eq "the post step runs the comparison after the transport" "match" \
  "$(jq -r '.account_match.status' "${root}/post-artifacts/aws-failure-diagnostics/identity-check.json" 2>/dev/null)"
check_eq "the original request IDs cross the boundary" "3" \
  "$(jq -r '[.test_context.aws_api_errors[].request_id | select(. != null)] | length' "${root}/post-artifacts/aws-failure-diagnostics/identity-check.json" 2>/dev/null)"
check_eq "the post step exits zero after the transport" "0" "$(cat "${root}/post-status")"
check_no_sentinels "no sentinel crosses the transport into the identity report" \
  "${root}/post-artifacts/aws-failure-diagnostics/identity-check.json"
check_eq "no node hostname crosses into the identity report" "0" \
  "$(grep -cF -e 'ip-10-0-107-53' -e 'compute.internal' "${root}/post-artifacts/aws-failure-diagnostics/identity-check.json" || true)"
check_eq "no node hostname reaches the post step output" "0" \
  "$(cat "${root}/post-stdout.txt" "${root}/post-stderr.txt" | grep -cF -e 'ip-10-0-107-53' -e 'compute.internal' || true)"
check_no_sentinels "no node hostname reaches the capture stdout" "${root}/produce-stdout.txt"
check_no_sentinels "no node hostname reaches the capture stderr" "${root}/produce-stderr.txt"

# Negative control: the subdirectory layout is dropped by the transport, so the
# post step never runs its comparison. This is what the flat case guards.
root="$(run_handoff nested nested)"
if [[ -e "${root}/consumed/aws-failure-diagnostics" ]]; then
  fail "a subdirectory does not survive the shared-directory transport"
else
  pass "a subdirectory does not survive the shared-directory transport"
fi
check_eq "a dropped handoff leaves the post step a no-op" "0" "$(cat "${root}/post-status")"
if [[ -e "${root}/post-artifacts/aws-failure-diagnostics" ]]; then
  fail "a dropped handoff produces no identity report"
else
  pass "a dropped handoff produces no identity report"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
