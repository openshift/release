#!/bin/bash

# Behavioral tests for the ROSA cluster lease controller's OCM authentication
# diagnostics.
#
# This phase runs before the controller writes its report, so a failure there
# leaves the step log as the only record. These tests drive the real
# `ocm_authenticate` against a stubbed `ocm` and assert that every outcome is
# described in the log -- phase, credential source, attempt number and final
# exit status -- while the supplied credentials and the stub's own output never
# appear in it. They also pin the retry shape (three attempts, two ten-second
# waits) and the propagated exit status, so a later change to the diagnostics
# cannot quietly change the behaviour around them.
#
# The controller script returns immediately when sourced, which is how these
# tests reach the authentication helpers without a cluster. They need only bash
# and the usual base utilities (cat, grep, sed, mktemp, date) -- no `oc`, `jq`
# or `python3` -- so unlike a full controller run they also work in the
# step-registry ShellCheck image that hack/validate-registry-commands.sh uses.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh"
TEST_ROOT=$(mktemp -d)

# Credential values the fixtures mount. They are deliberately distinctive so an
# assertion can prove they never reach the log, and distinct from the credential
# *file* names, which the diagnostics are allowed to print.
SSO_CLIENT_ID_VALUE='SSO_CLIENT_ID_ARGV_SENTINEL'
SSO_CLIENT_SECRET_VALUE='SSO_CLIENT_SECRET_ARGV_SENTINEL'
OCM_TOKEN_VALUE='OCM_TOKEN_ARGV_SENTINEL'

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Dump a file for context on failure. TEST_ROOT is removed by the EXIT trap, so
# a path printed in a FAIL message is already gone by the time anyone reads CI
# output. A run that died early may not have written the file at all, and `sed`
# on a missing file would abort the assertion under errexit before its FAIL
# message was printed.
dump() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    echo "--- ${file} ---" >&2
    sed -n '1,240p' "${file}" >&2
  else
    echo "(${file} was never written)" >&2
  fi
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq -- "${expected}" "${file}" 2>/dev/null; then
    dump "${file}"
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  # A missing file would make grep report "not found" and pass vacuously.
  [[ -f "${file}" ]] || fail "expected ${file} to exist"
  if grep -Fq -- "${unexpected}" "${file}" 2>/dev/null; then
    dump "${file}"
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

# Also dumps the step log, which is the only place that explains why a recorder
# holds the wrong value.
assert_file_contents() {
  local file="$1" expected="$2" description="$3" context="$4"
  local actual=""
  [[ ! -f "${file}" ]] || actual=$(cat "${file}")
  if [[ "${actual}" != "${expected}" ]]; then
    dump "${context}"
    dump "${file}"
    fail "${description}: expected '${expected}' in ${file}, got '${actual}'"
  fi
}

assert_login_attempts() {
  local case_dir="$1" expected="$2"
  assert_file_contents "${case_dir}/state/ocm-login-count" "${expected}" \
    "ocm login attempts" "${case_dir}/output.log"
}

# Two ten-second waits between three attempts, which this change must not alter.
assert_retry_waits() {
  local case_dir="$1" expected="$2"
  assert_file_contents "${case_dir}/state/sleep-delays" "${expected}" \
    "retry waits" "${case_dir}/output.log"
}

assert_no_login_attempted() {
  local case_dir="$1"
  if [[ -e "${case_dir}/state/ocm-login-count" ]]; then
    dump "${case_dir}/output.log"
    dump "${case_dir}/state/ocm-argv"
    fail "ocm login was attempted without a usable credential"
  fi
}

# The credentials must reach `ocm` -- otherwise "no secret in the log" would
# hold trivially -- on the expected flags and against the expected environment,
# and must not reach the log.
assert_login_invocation_but_not_logged() {
  local case_dir="$1" expected_argv="$2"
  assert_contains "${case_dir}/state/ocm-argv" "login --url ${expected_argv}"
  assert_no_secrets "${case_dir}/output.log"
}

assert_no_secrets() {
  local log="$1"
  assert_not_contains "${log}" "${SSO_CLIENT_ID_VALUE}"
  assert_not_contains "${log}" "${SSO_CLIENT_SECRET_VALUE}"
  assert_not_contains "${log}" "${OCM_TOKEN_VALUE}"
  assert_not_contains "${log}" '--client-secret'
  assert_not_contains "${log}" '--token'
  # Whatever ocm itself printed, including any credential echoed back.
  assert_not_contains "${log}" 'PROVIDER_RAW_STDOUT_SENTINEL'
  assert_not_contains "${log}" 'PROVIDER_RAW_STDERR_SENTINEL'
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  # Records every invocation, then behaves per MOCK_SCENARIO. The stub echoes
  # the credential it was handed back on both of its streams. That is a
  # worst-case stand-in rather than observed ocm behaviour: the step suppresses
  # that output precisely because it has not been vetted, and these tests hold
  # it to that regardless of what the real CLI prints.
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
set -o nounset

printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-argv"

if [[ "${1:-}" != "login" ]]; then
  exit 0
fi

count=0
[[ ! -f "${MOCK_STATE_DIR}/ocm-login-count" ]] || count=$(cat "${MOCK_STATE_DIR}/ocm-login-count")
count=$((count + 1))
printf '%s' "${count}" > "${MOCK_STATE_DIR}/ocm-login-count"

printf 'ocm: PROVIDER_RAW_STDOUT_SENTINEL\n'
printf 'ocm: PROVIDER_RAW_STDERR_SENTINEL: rejected %s\n' "$*" >&2

case "${MOCK_SCENARIO}" in
  login_succeeds)
    exit 0
    ;;
  login_recovers_on_third_attempt)
    (( count < 3 )) && exit 7
    exit 0
    ;;
  login_always_fails)
    exit 7
    ;;
  *)
    # Localize a renamed or typo'd scenario instead of silently succeeding.
    printf 'ocm stub: unknown MOCK_SCENARIO %s\n' "${MOCK_SCENARIO}" >&2
    exit 99
    ;;
esac
EOF

  # Keeps the two ten-second retry waits observable without spending them.
  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  chmod 0755 "${mock_dir}/ocm" "${mock_dir}/sleep"
}

# Build a case directory whose cluster profile holds the requested credentials.
new_case() {
  local case_dir="$1" credentials="$2"
  mkdir -p "${case_dir}/state" "${case_dir}/profile"
  make_mocks "${case_dir}/bin"
  case "${credentials}" in
    sso)
      printf '%s' "${SSO_CLIENT_ID_VALUE}" > "${case_dir}/profile/sso-client-id"
      printf '%s' "${SSO_CLIENT_SECRET_VALUE}" > "${case_dir}/profile/sso-client-secret"
      ;;
    token)
      printf '%s' "${OCM_TOKEN_VALUE}" > "${case_dir}/profile/ocm-token"
      ;;
    sso-and-token)
      printf '%s' "${SSO_CLIENT_ID_VALUE}" > "${case_dir}/profile/sso-client-id"
      printf '%s' "${SSO_CLIENT_SECRET_VALUE}" > "${case_dir}/profile/sso-client-secret"
      printf '%s' "${OCM_TOKEN_VALUE}" > "${case_dir}/profile/ocm-token"
      ;;
    client-id-only)
      printf '%s' "${SSO_CLIENT_ID_VALUE}" > "${case_dir}/profile/sso-client-id"
      ;;
    client-secret-and-token)
      printf '%s' "${SSO_CLIENT_SECRET_VALUE}" > "${case_dir}/profile/sso-client-secret"
      printf '%s' "${OCM_TOKEN_VALUE}" > "${case_dir}/profile/ocm-token"
      ;;
    empty-files)
      : > "${case_dir}/profile/sso-client-id"
      : > "${case_dir}/profile/sso-client-secret"
      : > "${case_dir}/profile/ocm-token"
      ;;
    none)
      ;;
    *)
      fail "unknown credential fixture: ${credentials}"
      ;;
  esac
}

# Source the controller script -- it returns right after defining the helpers --
# and run the real authentication entry point. With trace=true the caller has
# xtrace on when the script is sourced, which is how a debugging change to a
# parent script would expose every expanded credential. Returns the exit status.
run_authenticate() {
  local scenario="$1" case_dir="$2" trace="${3:-false}" rc=0
  local -a trace_args=()
  [[ "${trace}" != "true" ]] || trace_args=(-x)
  env \
    PATH="${case_dir}/bin:${PATH}" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    OCM_LOGIN_ENV=staging \
    bash "${trace_args[@]}" -c 'source "$1"; ocm_authenticate' _ "${COMMAND_SCRIPT}" \
    > "${case_dir}/output.log" 2>&1 || rc=$?
  return "${rc}"
}

test_successful_login_reports_phase_and_credential_source() {
  local case_dir="${TEST_ROOT}/login-succeeds"
  local rc=0
  new_case "${case_dir}" sso
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 0 "successful authentication"
  assert_contains "${case_dir}/output.log" "Phase 0: Authenticating to OCM (staging)"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging using sso-client-credentials succeeded on attempt 1/3"
  assert_login_attempts "${case_dir}" 1
  assert_retry_waits "${case_dir}" ""
  assert_login_invocation_but_not_logged "${case_dir}" \
    "staging --client-id ${SSO_CLIENT_ID_VALUE} --client-secret ${SSO_CLIENT_SECRET_VALUE}"
}

test_token_credentials_are_named_not_printed() {
  local case_dir="${TEST_ROOT}/login-token"
  local rc=0
  new_case "${case_dir}" token
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 0 "successful token authentication"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging using ocm-token succeeded on attempt 1/3"
  assert_not_contains "${case_dir}/output.log" "sso-client-credentials"
  assert_login_attempts "${case_dir}" 1
  assert_login_invocation_but_not_logged "${case_dir}" "staging --token ${OCM_TOKEN_VALUE}"
}

test_transient_failures_are_reported_per_attempt_and_recover() {
  local case_dir="${TEST_ROOT}/login-recovers"
  local rc=0
  new_case "${case_dir}" sso
  run_authenticate login_recovers_on_third_attempt "${case_dir}" || rc=$?

  assert_status "${rc}" 0 "authentication recovering on the third attempt"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging failed on attempt 1/3 with exit status 7"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging failed on attempt 2/3 with exit status 7"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging using sso-client-credentials succeeded on attempt 3/3"
  assert_not_contains "${case_dir}/output.log" "Phase 0 failed"
  assert_login_attempts "${case_dir}" 3
  assert_retry_waits "${case_dir}" $'10\n10'
  assert_login_invocation_but_not_logged "${case_dir}" \
    "staging --client-id ${SSO_CLIENT_ID_VALUE} --client-secret ${SSO_CLIENT_SECRET_VALUE}"
}

test_exhausted_login_reports_final_status_and_propagates_it() {
  local case_dir="${TEST_ROOT}/login-exhausted"
  local rc=0
  new_case "${case_dir}" sso
  run_authenticate login_always_fails "${case_dir}" || rc=$?

  assert_status "${rc}" 7 "exhausted authentication"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging failed on attempt 3/3 with exit status 7"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging failed after 3 attempts using sso-client-credentials; final exit status 7"
  assert_contains "${case_dir}/output.log" \
    "Phase 0 failed: OCM authentication to staging did not succeed; exiting with status 7"
  assert_not_contains "${case_dir}/output.log" "succeeded on attempt"
  assert_login_attempts "${case_dir}" 3
  assert_retry_waits "${case_dir}" $'10\n10'
  assert_login_invocation_but_not_logged "${case_dir}" \
    "staging --client-id ${SSO_CLIENT_ID_VALUE} --client-secret ${SSO_CLIENT_SECRET_VALUE}"
}

# Without a usable credential the step used to exit 1 having written nothing at
# all, which is indistinguishable from a crash in the step log.
test_missing_credentials_are_reported_by_input_name() {
  local case_dir="${TEST_ROOT}/no-credentials"
  local rc=0
  new_case "${case_dir}" none
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 1 "absent credentials"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging cannot be attempted: no usable credential in the cluster profile"
  assert_contains "${case_dir}/output.log" \
    "sso-client-id=missing sso-client-secret=missing ocm-token=missing"
  assert_contains "${case_dir}/output.log" \
    "Phase 0 failed: OCM authentication to staging did not succeed; exiting with status 1"
  assert_no_login_attempted "${case_dir}"
  assert_retry_waits "${case_dir}" ""
  assert_no_secrets "${case_dir}/output.log"
}

# A half-populated profile is the case the inventory exists for: it names which
# input is present and which is not, without printing either.
test_partial_credentials_are_reported_by_input_name() {
  local case_dir="${TEST_ROOT}/partial-credentials"
  local rc=0
  new_case "${case_dir}" client-id-only
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 1 "incomplete credentials"
  assert_contains "${case_dir}/output.log" \
    "sso-client-id=present sso-client-secret=missing ocm-token=missing"
  assert_no_login_attempted "${case_dir}"
  assert_no_secrets "${case_dir}/output.log"
}

# The diagnostics name the credential source, so the selection they describe
# has to be the one that was actually used. With both mounted, SSO wins.
test_sso_credentials_take_precedence_over_the_token() {
  local case_dir="${TEST_ROOT}/sso-and-token"
  local rc=0
  new_case "${case_dir}" sso-and-token
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 0 "both credentials present"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging using sso-client-credentials succeeded on attempt 1/3"
  assert_not_contains "${case_dir}/output.log" "using ocm-token"
  assert_login_invocation_but_not_logged "${case_dir}" \
    "staging --client-id ${SSO_CLIENT_ID_VALUE} --client-secret ${SSO_CLIENT_SECRET_VALUE}"
  assert_not_contains "${case_dir}/state/ocm-argv" "--token"
}

# An incomplete SSO pair is not a dead end while a token is also mounted: the
# run falls back, and the diagnostics must name the source it fell back to.
test_incomplete_sso_pair_falls_back_to_the_token() {
  local case_dir="${TEST_ROOT}/secret-and-token"
  local rc=0
  new_case "${case_dir}" client-secret-and-token
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 0 "incomplete SSO pair with a token"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging using ocm-token succeeded on attempt 1/3"
  assert_login_invocation_but_not_logged "${case_dir}" "staging --token ${OCM_TOKEN_VALUE}"
}

# A mounted-but-empty secret is a realistic Prow shape, and it must read as
# missing rather than be handed to ocm as an empty credential.
test_empty_credential_files_count_as_missing() {
  local case_dir="${TEST_ROOT}/empty-credentials"
  local rc=0
  new_case "${case_dir}" empty-files
  run_authenticate login_succeeds "${case_dir}" || rc=$?

  assert_status "${rc}" 1 "empty credential files"
  assert_contains "${case_dir}/output.log" \
    "sso-client-id=missing sso-client-secret=missing ocm-token=missing"
  assert_no_login_attempted "${case_dir}"
}

# CLAUDE.md names xtrace as the primary way a step-registry script leaks
# credentials into a publicly retained Prow log. The script disables it before
# touching any credential, so even a caller that turned it on gets a clean log.
test_xtrace_never_exposes_credentials() {
  local case_dir="${TEST_ROOT}/xtrace"
  local rc=0
  new_case "${case_dir}" sso-and-token
  run_authenticate login_always_fails "${case_dir}" true || rc=$?

  assert_status "${rc}" 7 "exhausted authentication under xtrace"
  # Proves tracing really was on and that the script's own `set +x` is what
  # turned it off; without this the case could pass with xtrace never enabled.
  assert_contains "${case_dir}/output.log" "++ set +x"
  assert_contains "${case_dir}/output.log" \
    "OCM login to staging failed after 3 attempts using sso-client-credentials; final exit status 7"
  assert_no_secrets "${case_dir}/output.log"
}

test_successful_login_reports_phase_and_credential_source
test_token_credentials_are_named_not_printed
test_transient_failures_are_reported_per_attempt_and_recover
test_exhausted_login_reports_final_status_and_propagates_it
test_missing_credentials_are_reported_by_input_name
test_partial_credentials_are_reported_by_input_name
test_sso_credentials_take_precedence_over_the_token
test_incomplete_sso_pair_falls_back_to_the_token
test_empty_credential_files_count_as_missing
test_xtrace_never_exposes_credentials

echo "PASS: rosa cluster lease OCM authentication diagnostics tests"
