#!/bin/bash

# Offline regression tests for the ROSA cluster lease health step.
#
# They cover the authentication path only: the step must record which
# credential kind it selected and which OCM environment it targeted before each
# fallible `ocm login` runs, so a login rejection can be triaged from the
# retained Prow artifacts alone. Everything the step publishes there is a fixed
# label it chose or an environment name normalized against a closed allowlist.
#
# Every credential here is a synthetic sentinel. The tests prove the sentinels
# still reach the mocked CLI -- authentication semantics are unchanged -- while
# never reaching anything the step itself writes to stdout, stderr or the
# artifact directory.
#
# The suite runs in the shellcheck validation image, which ships no jq, so the
# lease inventory is served through a jq stand-in backed by flat fixture files.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster-lease/health/rosa-cluster-lease-health-commands.sh"
DIAGNOSTICS_NAME="lease-health-auth-diagnostics.txt"
DEFAULT_LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
TEST_ROOT=$(mktemp -d)
cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

SSO_ID_SENTINEL="SSO-CLIENT-ID-SENTINEL-d41d8c"
SSO_SECRET_SENTINEL="SSO-CLIENT-SECRET-SENTINEL-9f86d0"
OCM_TOKEN_SENTINEL="OCM-TOKEN-SENTINEL-2c26b4"
SENTINEL_PATTERN='SENTINEL-d41d8c|SENTINEL-9f86d0|SENTINEL-2c26b4'

# Values a job or a lease ConfigMap controls. The diagnostics publish fixed
# labels and allowlisted names only, so neither may appear in them.
OCM_ENV_SENTINEL="OCM-LOGIN-ENV-SENTINEL-ef2d12"
CLUSTER_OCM_ENV_SENTINEL="CLUSTER-OCM-ENV-SENTINEL-18ac3e"

CASE_DIR=""
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

# Published output is stdout, stderr and everything under ARTIFACT_DIR.
assert_published_output_free_of() {
  local pattern="$1" description="$2"
  assert_pattern_absent "${CASE_DIR}/stdout.log" "${pattern}" "${description} on stdout"
  assert_pattern_absent "${CASE_DIR}/stderr.log" "${pattern}" "${description} on stderr"
  assert_pattern_absent "${CASE_DIR}/artifacts" "${pattern}" "${description} in artifacts"
}

assert_no_leaked_credentials() {
  assert_published_output_free_of "${SENTINEL_PATTERN}" "credential sentinel"
}

# Reads a file into CONTENTS preserving its exact bytes, trailing newlines
# included, which command substitution would strip. The validation image has no
# diffutils, so the comparison stays inside bash.
CONTENTS=""
read_file_exactly() {
  CONTENTS=""
  IFS= read -r -d '' CONTENTS < "$1" || true
}

assert_diagnostics_file() {
  local file="$1" stage="$2" auth_mode="$3" ocm_env="$4" expected
  [[ -f "${file}" ]] || fail "expected the diagnostics file ${file} to exist"
  printf -v expected 'stage: %s\nauth-mode: %s\nocm-env: %s\n' \
    "${stage}" "${auth_mode}" "${ocm_env}"
  read_file_exactly "${file}"
  [[ "${CONTENTS}" == "${expected}" ]] \
    || fail "unexpected diagnostics in ${file}: expected '${expected}', got '${CONTENTS}'"
}

assert_diagnostics() {
  assert_diagnostics_file "${CASE_DIR}/artifacts/${DIAGNOSTICS_NAME}" "$@"
}

# The snapshot the ocm mock takes when the n-th login starts, which proves the
# diagnostics were already on disk before that fallible call.
assert_diagnostics_at_login() {
  local attempt="$1"
  shift
  assert_diagnostics_file "${CASE_DIR}/state/diagnostics-at-login-${attempt}.txt" "$@"
}

make_mocks() {
  local mock_dir="${CASE_DIR}/bin"
  mkdir -p "${mock_dir}"

  # Records the credentials and the environment it was handed so the tests can
  # prove authentication still passes them, and snapshots the diagnostics
  # artifact at the moment each login is attempted. It prints the rejection
  # text the failing periodic runs showed; the step's own output is what the
  # leak assertions cover, so the mock deliberately adds nothing to it.
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-arguments"
if [[ "${1:-}" == "login" ]]; then
  count=0
  [[ ! -f "${MOCK_STATE_DIR}/ocm-login-count" ]] || count=$(cat "${MOCK_STATE_DIR}/ocm-login-count")
  count=$((count + 1))
  printf '%s' "${count}" > "${MOCK_STATE_DIR}/ocm-login-count"
  if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    cp "${ARTIFACT_DIR}/lease-health-auth-diagnostics.txt" \
      "${MOCK_STATE_DIR}/diagnostics-at-login-${count}.txt" 2>/dev/null || true
  fi
  case "${MOCK_SCENARIO}" in
    login_fails)
      printf 'Failed to create token: unauthorized_client\n' >&2
      exit 7
      ;;
    reauth_fails)
      if (( count > 1 )); then
        printf 'Failed to create token: unauthorized_client\n' >&2
        exit 7
      fi
      ;;
  esac
fi
# As with the inventory, the body is opaque and the jq stand-in resolves the
# fields a test asked for from fixture files.
case "$*" in
  "get /api/clusters_mgmt/v1/clusters/"*)
    printf 'OCM-CLUSTER\n'
    ;;
esac
exit 0
EOF

  # The lease host is unreachable offline. The inventory body is opaque: the jq
  # stand-in below resolves every field from fixture files instead.
  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/oc-arguments"
case "$*" in
  *"get configmap"*"-o json"*)
    printf 'INVENTORY\n'
    ;;
esac
exit 0
EOF

  # Answers only the filters this step uses on the paths these tests reach, and
  # reproduces real jq's defaults for an absent field so a fixture can model a
  # ConfigMap that omits one. An unanswered filter exits non-zero; most call
  # sites then abort the step, but the two that silence jq would degrade
  # instead, so a new fixture reaching those needs an arm added here.
  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
filter="${*: -1}"
input=$(cat)

# The fixture value for a field, or what real jq prints when it is absent.
field() {
  local file="${MOCK_STATE_DIR}/${input}-$1" value=""
  [[ ! -f "${file}" ]] || value=$(cat "${file}")
  printf '%s\n' "${value:-$2}"
}

case "${filter}" in
  '.items | length')
    cat "${MOCK_STATE_DIR}/inventory-count"
    ;;
  '.items['*']')
    index="${filter#.items[}"
    printf 'cluster-%s\n' "${index%]}"
    ;;
  '.metadata.name')
    field name null
    ;;
  '.data["cluster-id"]')
    field cluster-id null
    ;;
  '.metadata.labels["rosa-cluster-lease/status"]')
    field status null
    ;;
  '.metadata.annotations["rosa-cluster-lease/holder"] // ""')
    field holder ""
    ;;
  '.metadata.annotations["rosa-cluster-lease/acquired-at"] // ""')
    field acquired-at ""
    ;;
  '.data["ocm-env"] // "staging"')
    field ocm-env staging
    ;;
  '.status.state // "unknown"')
    field state unknown
    ;;
  *)
    printf 'the jq fixture has no answer for the filter: %s\n' "${filter}" >&2
    exit 90
    ;;
esac
EOF

  chmod 0755 "${mock_dir}"/*
}

setup_case() {
  local name="$1"
  OMIT_ENV=()
  EXTRA_ENV=()
  CASE_DIR="${TEST_ROOT}/${name}"
  mkdir -p "${CASE_DIR}/artifacts" "${CASE_DIR}/profile" "${CASE_DIR}/state"
  printf 'not-a-real-kubeconfig\n' > "${CASE_DIR}/lease-kubeconfig"
  printf '0' > "${CASE_DIR}/state/inventory-count"
  make_mocks
}

# Appends one lease ConfigMap to the fixture inventory.
add_lease_fixture() {
  local name="$1" status="$2" holder="$3" acquired_at="$4" cluster_id="$5" ocm_env="$6"
  local index
  index=$(cat "${CASE_DIR}/state/inventory-count")
  printf '%s\n' "${name}" > "${CASE_DIR}/state/cluster-${index}-name"
  printf '%s\n' "${status}" > "${CASE_DIR}/state/cluster-${index}-status"
  printf '%s\n' "${holder}" > "${CASE_DIR}/state/cluster-${index}-holder"
  printf '%s\n' "${acquired_at}" > "${CASE_DIR}/state/cluster-${index}-acquired-at"
  printf '%s\n' "${cluster_id}" > "${CASE_DIR}/state/cluster-${index}-cluster-id"
  printf '%s\n' "${ocm_env}" > "${CASE_DIR}/state/cluster-${index}-ocm-env"
  printf '%s' "$((index + 1))" > "${CASE_DIR}/state/inventory-count"
}

# The cluster state OCM reports back. Anything but "ready" stops the step
# before the ClusterPackage checks, which this suite, scoped to the
# authentication paths, deliberately leaves uncovered.
set_ocm_cluster_state() {
  printf '%s\n' "$1" > "${CASE_DIR}/state/OCM-CLUSTER-state"
}

write_sso_credentials() {
  printf '%s\n' "${SSO_ID_SENTINEL}" > "${CASE_DIR}/profile/sso-client-id"
  printf '%s\n' "${SSO_SECRET_SENTINEL}" > "${CASE_DIR}/profile/sso-client-secret"
}

write_token_credential() {
  printf '%s\n' "${OCM_TOKEN_SENTINEL}" > "${CASE_DIR}/profile/ocm-token"
}

run_health() {
  local scenario="$1" assignment omitted keep
  local -a assignments=(
    "PATH=${CASE_DIR}/bin:${PATH}"
    "HOME=${CASE_DIR}"
    "MOCK_STATE_DIR=${CASE_DIR}/state"
    "MOCK_SCENARIO=${scenario}"
    "ARTIFACT_DIR=${CASE_DIR}/artifacts"
    "CLUSTER_PROFILE_DIR=${CASE_DIR}/profile"
    "LEASE_HOST_KUBECONFIG=${CASE_DIR}/lease-kubeconfig"
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

test_sso_client_pair_is_recorded_before_login() {
  setup_case sso-client-pair
  write_sso_credentials
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check with an SSO client pair"
  assert_diagnostics_at_login 1 ocm-login sso-client-pair staging
  assert_diagnostics ocm-login-succeeded sso-client-pair staging
  assert_contains "${CASE_DIR}/stderr.log" \
    "OCM auth: stage=ocm-login auth-mode=sso-client-pair ocm-env=staging"
  # Authentication semantics are unchanged: the client pair still reaches the CLI.
  assert_contains "${CASE_DIR}/state/ocm-arguments" "--client-id ${SSO_ID_SENTINEL}"
  assert_contains "${CASE_DIR}/state/ocm-arguments" "--client-secret ${SSO_SECRET_SENTINEL}"
  assert_not_contains "${CASE_DIR}/state/ocm-arguments" "--token"
  assert_no_leaked_credentials
}

test_token_credential_is_recorded_before_login() {
  setup_case ocm-token
  write_token_credential
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check with an OCM token"
  assert_diagnostics_at_login 1 ocm-login ocm-token staging
  assert_diagnostics ocm-login-succeeded ocm-token staging
  assert_contains "${CASE_DIR}/state/ocm-arguments" "--token ${OCM_TOKEN_SENTINEL}"
  assert_not_contains "${CASE_DIR}/state/ocm-arguments" "--client-id"
  assert_no_leaked_credentials
}

test_a_complete_client_pair_is_preferred_over_a_token() {
  setup_case sso-pair-and-token
  write_sso_credentials
  write_token_credential
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check with both credential kinds"
  # Credential precedence is unchanged, and the diagnostics name the kind used.
  assert_diagnostics ocm-login-succeeded sso-client-pair staging
  assert_contains "${CASE_DIR}/state/ocm-arguments" "--client-id ${SSO_ID_SENTINEL}"
  assert_not_contains "${CASE_DIR}/state/ocm-arguments" "--token"
  assert_no_leaked_credentials
}

test_a_lone_client_id_still_selects_the_token_credential() {
  setup_case partial-sso-pair
  printf '%s\n' "${SSO_ID_SENTINEL}" > "${CASE_DIR}/profile/sso-client-id"
  write_token_credential
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check with an incomplete SSO client pair"
  assert_diagnostics ocm-login-succeeded ocm-token staging
  assert_contains "${CASE_DIR}/state/ocm-arguments" "--token ${OCM_TOKEN_SENTINEL}"
  assert_no_leaked_credentials
}

test_missing_credentials_are_reported_without_attempting_login() {
  setup_case no-credentials
  run_health login_succeeds

  assert_status "${STATUS}" 1 "health check without any credential"
  assert_diagnostics ocm-login none staging
  assert_contains "${CASE_DIR}/stderr.log" "ERROR: No OCM credentials found in cluster profile"
  [[ ! -f "${CASE_DIR}/state/ocm-login-count" ]] || fail "login was attempted without a credential"
  assert_no_leaked_credentials
}

test_login_failure_keeps_its_exit_status_and_the_pre_login_stage() {
  setup_case login-rejected
  write_sso_credentials
  run_health login_fails

  # The step must not swallow, retry or re-map the CLI's exit status.
  assert_status "${STATUS}" 7 "health check with a rejected login"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "1"
  # The surviving artifact names the stage that failed and how it authenticated.
  assert_diagnostics ocm-login sso-client-pair staging
  assert_contains "${CASE_DIR}/stderr.log" "unauthorized_client"
  [[ ! -f "${CASE_DIR}/artifacts/lease-health-report.txt" ]] \
    || fail "the lease health report ran after a failed login"
  assert_no_leaked_credentials
}

test_allowlisted_ocm_environments_are_named() {
  local ocm_env
  for ocm_env in production staging integration local; do
    setup_case "ocm-env-${ocm_env}"
    write_token_credential
    EXTRA_ENV=("OCM_LOGIN_ENV=${ocm_env}")
    run_health login_succeeds

    assert_status "${STATUS}" 0 "health check against the ${ocm_env} environment"
    assert_diagnostics ocm-login-succeeded ocm-token "${ocm_env}"
    assert_no_leaked_credentials
  done
}

test_unrecognized_ocm_environment_is_reported_as_other() {
  setup_case ocm-env-unrecognized
  write_token_credential
  EXTRA_ENV=("OCM_LOGIN_ENV=https://api.fixture.invalid/${OCM_ENV_SENTINEL}")
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check against an unrecognized environment"
  assert_diagnostics ocm-login-succeeded ocm-token other
  # The job-supplied value reaches the CLI but never the published output.
  assert_pattern_present "${CASE_DIR}/state/ocm-arguments" "${OCM_ENV_SENTINEL}" "the ocm CLI"
  assert_published_output_free_of "${OCM_ENV_SENTINEL}" "environment value"
  assert_no_leaked_credentials
}

test_undeliverable_diagnostics_do_not_change_the_exit_status() {
  setup_case diagnostics-undeliverable
  write_sso_credentials
  # A directory in place of the file makes every write fail for any user.
  mkdir "${CASE_DIR}/artifacts/${DIAGNOSTICS_NAME}"
  run_health login_fails

  assert_status "${STATUS}" 7 "health check whose diagnostics cannot be written"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "1"
  assert_contains "${CASE_DIR}/stderr.log" \
    "WARNING: could not write the OCM auth diagnostics to the artifact directory"
  assert_contains "${CASE_DIR}/stderr.log" \
    "OCM auth: stage=ocm-login auth-mode=sso-client-pair ocm-env=staging"
  assert_no_leaked_credentials
}

test_absent_artifact_dir_does_not_change_the_exit_status() {
  setup_case no-artifact-dir
  write_sso_credentials
  OMIT_ENV=("ARTIFACT_DIR")
  run_health login_fails

  # The login still runs and still decides the exit status, exactly as before.
  assert_status "${STATUS}" 7 "health check without an artifact directory"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "1"
  assert_contains "${CASE_DIR}/stderr.log" \
    "OCM auth: stage=ocm-login auth-mode=sso-client-pair ocm-env=staging"
  [[ -z "$(ls -A "${CASE_DIR}/artifacts")" ]] || fail "wrote artifacts without ARTIFACT_DIR"
  assert_no_leaked_credentials
}

test_the_default_kubeconfig_path_is_used_when_unset() {
  # The case asserts the step cannot find the mount, so it only means anything
  # where the mount is absent. The validation image has no such path.
  if [[ -e "${DEFAULT_LEASE_HOST_KUBECONFIG}" ]]; then
    echo "SKIP: ${DEFAULT_LEASE_HOST_KUBECONFIG} exists on this host" >&2
    return 0
  fi
  setup_case default-kubeconfig
  write_sso_credentials
  OMIT_ENV=("LEASE_HOST_KUBECONFIG")
  run_health login_succeeds

  # The override is only a test seam; without it the step takes the mount path.
  assert_status "${STATUS}" 1 "health check without the kubeconfig override"
  assert_contains "${CASE_DIR}/stderr.log" \
    "ERROR: Lease host kubeconfig not found at ${DEFAULT_LEASE_HOST_KUBECONFIG}"
  [[ ! -f "${CASE_DIR}/artifacts/${DIAGNOSTICS_NAME}" ]] \
    || fail "authentication ran before the prerequisite check"
  assert_no_leaked_credentials
}

test_reauthentication_records_its_own_stage_and_environment() {
  setup_case reauth-rejected
  write_sso_credentials
  # An available lease in another environment makes the step log in again.
  add_lease_fixture lease-fixture available "" "" fixture-cluster-id production
  run_health reauth_fails

  assert_status "${STATUS}" 7 "health check with a rejected re-authentication"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "2"
  assert_diagnostics_at_login 2 ocm-reauth sso-client-pair production
  # The artifact names the login that actually failed, not the one that worked.
  assert_diagnostics ocm-reauth sso-client-pair production
  assert_no_leaked_credentials
}

test_successful_reauthentication_records_its_own_succeeded_stage() {
  setup_case reauth-succeeded
  write_sso_credentials
  # An available lease in another environment makes the step log in again.
  add_lease_fixture lease-fixture available "" "" fixture-cluster-id production
  set_ocm_cluster_state error
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check that re-authenticates successfully"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "2"
  assert_diagnostics_at_login 2 ocm-reauth sso-client-pair production
  # The second login worked, so the artifact advances past the stage it names
  # while that login is in flight.
  assert_diagnostics ocm-reauth-succeeded sso-client-pair production
  assert_contains "${CASE_DIR}/stderr.log" \
    "OCM auth: stage=ocm-reauth-succeeded auth-mode=sso-client-pair ocm-env=production"
  assert_no_leaked_credentials
}

test_reauthentication_environment_outside_the_allowlist_is_other() {
  setup_case reauth-unrecognized-env
  write_sso_credentials
  # The per-cluster environment comes from a ConfigMap, so it is as arbitrary
  # as a job-supplied value and must be normalized the same way.
  add_lease_fixture lease-fixture available "" "" fixture-cluster-id \
    "https://api.fixture.invalid/${CLUSTER_OCM_ENV_SENTINEL}"
  run_health reauth_fails

  assert_status "${STATUS}" 7 "health check re-authenticating to an unrecognized environment"
  assert_diagnostics ocm-reauth sso-client-pair other
  assert_pattern_present "${CASE_DIR}/state/ocm-arguments" "${CLUSTER_OCM_ENV_SENTINEL}" "the ocm CLI"
  assert_published_output_free_of "${CLUSTER_OCM_ENV_SENTINEL}" "lease environment value"
  assert_no_leaked_credentials
}

test_lease_health_reporting_is_unchanged() {
  setup_case lease-health-report
  write_sso_credentials
  local acquired_at
  acquired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  add_lease_fixture lease-fixture in-use fixture-job "${acquired_at}" fixture-cluster-id staging
  run_health login_succeeds

  assert_status "${STATUS}" 0 "health check over a one-cluster inventory"
  assert_diagnostics ocm-login-succeeded sso-client-pair staging
  # The report, its contents and the summary counters are untouched by the
  # diagnostics, and the diagnostics live in their own file.
  local report="${CASE_DIR}/artifacts/lease-health-report.txt"
  assert_contains "${report}" "Cluster: lease-fixture (fixture-cluster-id)"
  assert_contains "${report}" "Status: in-use"
  assert_contains "${report}" "Holder: fixture-job"
  assert_contains "${report}" "Summary: 1 healthy, 0 unhealthy, 0 recovered"
  assert_not_contains "${report}" "auth-mode:"
  # A healthy in-use lease is left alone and needs no second login.
  assert_not_contains "${CASE_DIR}/state/oc-arguments" "patch"
  assert_file_contents "${CASE_DIR}/state/ocm-login-count" "1"
  assert_no_leaked_credentials
}

test_sso_client_pair_is_recorded_before_login
test_token_credential_is_recorded_before_login
test_a_complete_client_pair_is_preferred_over_a_token
test_a_lone_client_id_still_selects_the_token_credential
test_missing_credentials_are_reported_without_attempting_login
test_login_failure_keeps_its_exit_status_and_the_pre_login_stage
test_allowlisted_ocm_environments_are_named
test_unrecognized_ocm_environment_is_reported_as_other
test_undeliverable_diagnostics_do_not_change_the_exit_status
test_absent_artifact_dir_does_not_change_the_exit_status
test_the_default_kubeconfig_path_is_used_when_unset
test_reauthentication_records_its_own_stage_and_environment
test_successful_reauthentication_records_its_own_succeeded_stage
test_reauthentication_environment_outside_the_allowlist_is_other
test_lease_health_reporting_is_unchanged

echo "PASS: rosa cluster lease health auth diagnostics tests"
