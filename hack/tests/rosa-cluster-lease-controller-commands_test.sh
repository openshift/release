#!/bin/bash

# Offline regression tests for the ROSA cluster lease controller step.
#
# They cover the startup path only: the controller must create its report and
# record the failing stage with its exit status before and during the fallible
# startup steps, while keeping credential material out of stdout, stderr and
# the artifacts. Every credential here is a synthetic sentinel; the tests prove
# the sentinels reach the mocked CLI but never any published output.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster-lease/controller/rosa-cluster-lease-controller-commands.sh"
TEST_ROOT=$(mktemp -d)
cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

SSO_ID_SENTINEL="SSO-CLIENT-ID-SENTINEL-d41d8c"
SSO_SECRET_SENTINEL="SSO-CLIENT-SECRET-SENTINEL-9f86d0"
OCM_TOKEN_SENTINEL="OCM-TOKEN-SENTINEL-2c26b4"
SENTINEL_PATTERN='SENTINEL-d41d8c|SENTINEL-9f86d0|SENTINEL-2c26b4'

# Environment-supplied values. The startup diagnostics publish fixed labels and
# allowlisted names only, so neither of these may appear in them even though a
# job controls both. The kubeconfig path additionally keeps reaching stderr
# through the pre-existing error message, which this change does not alter.
KUBECONFIG_PATH_SENTINEL="LEASE-KUBECONFIG-PATH-SENTINEL-fcde2b"
OCM_ENV_SENTINEL="OCM-LOGIN-ENV-SENTINEL-ef2d12"
DEFAULT_LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"

CASE_DIR=""
KUBECONFIG_PATH=""
STATUS=0
# Names of the environment variables a single run leaves unset.
OMIT_ENV=()
# Extra VAR=VALUE assignments for a single run.
EXTRA_ENV=()

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,120p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "${unexpected}" "${file}"; then
    sed -n '1,120p' "${file}" >&2
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_non_empty() {
  local file="$1" description="$2"
  [[ -s "${file}" ]] || fail "${description}: expected ${file} to be non-empty"
}

assert_file_contents() {
  local file="$1" expected="$2"
  local actual=""
  [[ ! -f "${file}" ]] || actual=$(cat "${file}")
  [[ "${actual}" == "${expected}" ]] || fail "expected ${file} to contain '${expected}', got '${actual}'"
}

assert_pattern_present() {
  local path="$1" pattern="$2" description="$3"
  grep -REq -- "${pattern}" "${path}" \
    || fail "${description}: expected '${pattern}' to reach ${path}"
}

assert_pattern_absent() {
  local path="$1" pattern="$2" description="$3"
  if grep -REq -- "${pattern}" "${path}"; then
    grep -REn -- "${pattern}" "${path}" >&2 || true
    fail "${description}: '${pattern}' leaked into ${path}"
  fi
}

assert_sentinels_present() {
  local path="$1" description="$2"
  assert_pattern_present "${path}" "${SENTINEL_PATTERN}" "${description}"
}

assert_no_sentinels() {
  local path="$1" description="$2"
  assert_pattern_absent "${path}" "${SENTINEL_PATTERN}" "${description}"
}

# The startup diagnostics are stdout plus everything under ARTIFACT_DIR; an
# environment-derived value must never appear in either.
assert_diagnostics_free_of() {
  local pattern="$1" description="$2"
  assert_pattern_absent "${CASE_DIR}/stdout.log" "${pattern}" "${description} on stdout"
  assert_pattern_absent "${CASE_DIR}/artifacts" "${pattern}" "${description} in artifacts"
}

# Published output is stdout, stderr and everything under ARTIFACT_DIR.
assert_no_leaked_credentials() {
  assert_no_sentinels "${CASE_DIR}/stdout.log" "stdout"
  assert_no_sentinels "${CASE_DIR}/stderr.log" "stderr"
  assert_no_sentinels "${CASE_DIR}/artifacts" "artifacts"
}

make_mocks() {
  local mock_dir="${CASE_DIR}/bin"
  mkdir -p "${mock_dir}"

  # Mimics a CLI that echoes the credentials it was handed back to the caller,
  # which is exactly what the step has to keep out of the Prow log.
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-arguments"
if [[ "${1:-}" == "login" ]]; then
  count=0
  [[ ! -f "${MOCK_STATE_DIR}/ocm-login-count" ]] || count=$(cat "${MOCK_STATE_DIR}/ocm-login-count")
  printf '%s' "$((count + 1))" > "${MOCK_STATE_DIR}/ocm-login-count"
  if [[ "${MOCK_SCENARIO}" == "login_fails" ]]; then
    printf 'ocm login failed with %s\n' "$*"
    printf 'ocm login failed with %s\n' "$*" >&2
    exit 7
  fi
  exit 0
fi
exit 0
EOF

  # The lease host is unreachable offline, so reconciliation stops in phase 1.
  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/oc-arguments"
exit 1
EOF

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  chmod 0755 "${mock_dir}"/*
}

setup_case() {
  local name="$1"
  OMIT_ENV=()
  EXTRA_ENV=()
  CASE_DIR="${TEST_ROOT}/${name}"
  mkdir -p "${CASE_DIR}/artifacts" "${CASE_DIR}/profile" "${CASE_DIR}/state"
  KUBECONFIG_PATH="${CASE_DIR}/lease-kubeconfig"
  printf 'not-a-real-kubeconfig\n' > "${KUBECONFIG_PATH}"
  make_mocks
}

write_sso_credentials() {
  printf '%s\n' "${SSO_ID_SENTINEL}" > "${CASE_DIR}/profile/sso-client-id"
  printf '%s\n' "${SSO_SECRET_SENTINEL}" > "${CASE_DIR}/profile/sso-client-secret"
}

write_token_credential() {
  printf '%s\n' "${OCM_TOKEN_SENTINEL}" > "${CASE_DIR}/profile/ocm-token"
}

run_controller() {
  local scenario="$1" assignment omitted keep
  local -a assignments=(
    "PATH=${CASE_DIR}/bin:${PATH}"
    "HOME=${CASE_DIR}"
    "MOCK_STATE_DIR=${CASE_DIR}/state"
    "MOCK_SCENARIO=${scenario}"
    "ARTIFACT_DIR=${CASE_DIR}/artifacts"
    "CLUSTER_PROFILE_DIR=${CASE_DIR}/profile"
    "LEASE_HOST_KUBECONFIG=${KUBECONFIG_PATH}"
  )
  assignments+=(${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"})
  local -a environment=()
  for assignment in "${assignments[@]}"; do
    keep=true
    for omitted in ${OMIT_ENV[@]+"${OMIT_ENV[@]}"}; do
      [[ "${assignment%%=*}" != "${omitted}" ]] || keep=false
    done
    [[ "${keep}" == false ]] || environment+=("${assignment}")
  done

  set +o errexit
  env -i "${environment[@]}" "${BASH}" "${COMMAND_SCRIPT}" \
    > "${CASE_DIR}/stdout.log" 2> "${CASE_DIR}/stderr.log"
  STATUS=$?
  set -o errexit
}

test_sourcing_defines_functions_without_side_effects() {
  setup_case sourceable
  set +o errexit
  env -i PATH="${PATH}" HOME="${CASE_DIR}" "${BASH}" -c '
    set -o nounset
    source "$1"
    declare -F ocm_login ocm_authenticate ocm_ensure_env > /dev/null || exit 2
    echo FUNCTIONS_DEFINED
  ' _ "${COMMAND_SCRIPT}" > "${CASE_DIR}/stdout.log" 2> "${CASE_DIR}/stderr.log"
  STATUS=$?
  set -o errexit

  assert_status "${STATUS}" 0 "sourcing the step script"
  assert_contains "${CASE_DIR}/stdout.log" "FUNCTIONS_DEFINED"
  # Sourcing must not run the startup path, so it needs no ARTIFACT_DIR.
  assert_not_contains "${CASE_DIR}/stdout.log" "stage="
  [[ -z "$(ls -A "${CASE_DIR}/artifacts")" ]] || fail "sourcing the step script wrote artifacts"
}

test_unset_artifact_dir_is_reported_on_stdout() {
  setup_case no-artifact-dir
  write_sso_credentials
  OMIT_ENV=("ARTIFACT_DIR")
  run_controller login_succeeds

  assert_status "${STATUS}" 1 "startup without ARTIFACT_DIR"
  assert_contains "${CASE_DIR}/stdout.log" "FAILED: stage=init exit_status=1 detail=artifact-dir-not-set"
  [[ -z "$(ls -A "${CASE_DIR}/artifacts")" ]] || fail "no report can be written without ARTIFACT_DIR"
  assert_no_leaked_credentials
}

test_unexpected_startup_abort_is_still_reported() {
  setup_case startup-abort
  write_sso_credentials
  # An unset CLUSTER_PROFILE_DIR aborts under `nounset` without passing through
  # fail_stage; the trap must still leave a build log and a report behind.
  OMIT_ENV=("CLUSTER_PROFILE_DIR")
  run_controller login_succeeds

  assert_status "${STATUS}" 1 "startup aborted by an unbound variable"
  assert_non_empty "${CASE_DIR}/stdout.log" "startup abort build log"
  assert_contains "${CASE_DIR}/stdout.log" \
    "FAILED: stage=prerequisites exit_status=1 detail=no-stage-diagnostics"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" \
    "FAILED: stage=prerequisites exit_status=1 detail=no-stage-diagnostics"
  [[ ! -f "${CASE_DIR}/state/ocm-login-count" ]] || fail "authentication ran after a startup abort"
  assert_no_leaked_credentials
}

test_missing_prerequisite_reports_fixed_label_not_the_path() {
  setup_case missing-kubeconfig
  write_sso_credentials
  # A job-controlled path. The new diagnostics must name the prerequisite with
  # a fixed label instead of echoing the configured location back.
  KUBECONFIG_PATH="${CASE_DIR}/${KUBECONFIG_PATH_SENTINEL}"
  run_controller login_succeeds

  assert_status "${STATUS}" 1 "missing lease host kubeconfig"
  assert_non_empty "${CASE_DIR}/stdout.log" "startup failure build log"
  assert_contains "${CASE_DIR}/stdout.log" \
    "FAILED: stage=prerequisites exit_status=1 detail=file-not-found file=lease-host-kubeconfig"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" \
    "FAILED: stage=prerequisites exit_status=1 detail=file-not-found file=lease-host-kubeconfig"
  assert_diagnostics_free_of "${KUBECONFIG_PATH_SENTINEL}" "configured kubeconfig path"
  # Unchanged pre-existing behavior: the human-readable error on stderr still
  # names the location it looked in.
  assert_contains "${CASE_DIR}/stderr.log" "ERROR: Lease host kubeconfig not found"
  assert_pattern_present "${CASE_DIR}/stderr.log" "${KUBECONFIG_PATH_SENTINEL}" \
    "pre-existing stderr error"
  [[ ! -f "${CASE_DIR}/state/ocm-login-count" ]] || fail "authentication ran before prerequisites passed"
  assert_no_leaked_credentials
}

test_default_kubeconfig_path_is_used_when_unset() {
  if [[ -e "${DEFAULT_LEASE_HOST_KUBECONFIG}" ]]; then
    echo "SKIP: ${DEFAULT_LEASE_HOST_KUBECONFIG} exists in this environment" >&2
    return 0
  fi
  setup_case default-kubeconfig
  write_sso_credentials
  # The override is only a test seam: with it unset -- as in every CI run,
  # where the step ref does not declare it -- the mounted bundle path is used.
  OMIT_ENV=("LEASE_HOST_KUBECONFIG")
  run_controller login_succeeds

  assert_status "${STATUS}" 1 "startup with the default kubeconfig path"
  assert_contains "${CASE_DIR}/stderr.log" \
    "ERROR: Lease host kubeconfig not found at ${DEFAULT_LEASE_HOST_KUBECONFIG}"
  assert_contains "${CASE_DIR}/stdout.log" \
    "FAILED: stage=prerequisites exit_status=1 detail=file-not-found file=lease-host-kubeconfig"
  [[ ! -f "${CASE_DIR}/state/ocm-login-count" ]] || fail "authentication ran before prerequisites passed"
  assert_no_leaked_credentials
}

test_ocm_login_env_is_normalized_in_diagnostics() {
  setup_case ocm-env-override
  write_sso_credentials
  # OCM_LOGIN_ENV is a declared, job-controlled step variable that ocm also
  # accepts as a URL; diagnostics must reduce an unknown value to a label.
  EXTRA_ENV=("OCM_LOGIN_ENV=${OCM_ENV_SENTINEL}")
  run_controller login_fails

  assert_status "${STATUS}" 7 "exhausted ocm login retries"
  assert_contains "${CASE_DIR}/stdout.log" \
    "FAILED: stage=ocm-authenticate exit_status=7 auth_mode=sso-client-credentials attempts=3 ocm_env=other missing_credential_files=ocm-token"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" "ocm_env=other"
  assert_diagnostics_free_of "${OCM_ENV_SENTINEL}" "configured OCM login environment"
  assert_pattern_absent "${CASE_DIR}/stderr.log" "${OCM_ENV_SENTINEL}" "stderr"
  # The value still reached the CLI unchanged, so the login behavior itself is
  # untouched by the normalization.
  assert_pattern_present "${CASE_DIR}/state/ocm-arguments" "${OCM_ENV_SENTINEL}" "ocm login arguments"
  assert_no_leaked_credentials
}

test_missing_credentials_report_file_names_only() {
  setup_case missing-credentials
  run_controller login_succeeds

  assert_status "${STATUS}" 1 "authentication without credentials"
  assert_non_empty "${CASE_DIR}/stdout.log" "startup failure build log"
  assert_contains "${CASE_DIR}/stdout.log" \
    "FAILED: stage=ocm-authenticate exit_status=1 auth_mode=none attempts=0 ocm_env=staging missing_credential_files=sso-client-id,sso-client-secret,ocm-token"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" "Lease Controller Report"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" \
    "FAILED: stage=ocm-authenticate exit_status=1 auth_mode=none"
  [[ ! -f "${CASE_DIR}/state/ocm-login-count" ]] || fail "ocm login attempted without credentials"
  assert_no_leaked_credentials
}

test_login_failure_keeps_retries_exit_status_and_secrecy() {
  setup_case login-failure
  write_sso_credentials
  run_controller login_fails

  assert_status "${STATUS}" 7 "exhausted ocm login retries"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "3"
  assert_file_contents "${CASE_DIR}/state/sleep-delays" $'10\n10'
  assert_contains "${CASE_DIR}/stdout.log" \
    "FAILED: stage=ocm-authenticate exit_status=7 auth_mode=sso-client-credentials attempts=3 ocm_env=staging missing_credential_files=ocm-token"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" \
    "FAILED: stage=ocm-authenticate exit_status=7 auth_mode=sso-client-credentials attempts=3"
  # The mocked CLI really did receive the credentials and really did echo them,
  # so the absence checks below are meaningful.
  assert_sentinels_present "${CASE_DIR}/state/ocm-arguments" "ocm login arguments"
  assert_not_contains "${CASE_DIR}/stdout.log" "ocm login failed with"
  assert_not_contains "${CASE_DIR}/stderr.log" "ocm login failed with"
  assert_no_leaked_credentials
}

test_successful_authentication_is_recorded_and_startup_trap_cleared() {
  setup_case login-success
  write_token_credential
  run_controller login_succeeds

  # Reconciliation stops in phase 1 because the lease host is mocked away; the
  # startup breadcrumbs must still show that startup itself succeeded.
  assert_status "${STATUS}" 1 "phase 1 without a reachable lease host"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "1"
  assert_contains "${CASE_DIR}/stdout.log" \
    "OK: stage=ocm-authenticate auth_mode=ocm-token attempts=1 ocm_env=staging"
  assert_contains "${CASE_DIR}/artifacts/controller-report.txt" \
    "OK: stage=ocm-authenticate auth_mode=ocm-token attempts=1"
  assert_not_contains "${CASE_DIR}/stdout.log" "FAILED: stage="
  assert_not_contains "${CASE_DIR}/artifacts/controller-report.txt" "FAILED: stage="
  assert_contains "${CASE_DIR}/stderr.log" "ERROR: rosa-cluster-lease-config ConfigMap not found"
  assert_sentinels_present "${CASE_DIR}/state/ocm-arguments" "ocm login arguments"
  assert_no_leaked_credentials
}

test_sourcing_defines_functions_without_side_effects
test_unset_artifact_dir_is_reported_on_stdout
test_unexpected_startup_abort_is_still_reported
test_missing_prerequisite_reports_fixed_label_not_the_path
test_default_kubeconfig_path_is_used_when_unset
test_ocm_login_env_is_normalized_in_diagnostics
test_missing_credentials_report_file_names_only
test_login_failure_keeps_retries_exit_status_and_secrecy
test_successful_authentication_is_recorded_and_startup_trap_cleared

echo "PASS: rosa cluster lease controller startup diagnostics tests"
