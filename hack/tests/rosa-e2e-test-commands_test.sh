#!/bin/bash

# Behavioural tests for the rosa-e2e-test step command script.
#
# The step runs its setup under errexit/pipefail and deliberately discards the
# stderr of the management-cluster lookups so credentials never reach the
# publicly retained Prow log. These tests pin the two properties that made a
# failure in that setup undebuggable before the setup-stage diagnostics existed:
#
#   1. every way the setup can abort reports which stage aborted and with what
#      status, and the status itself is unchanged by the reporting;
#   2. nothing the step prints ever contains data from a credentialed command.
#
# For (2) every credential fixture carries a sentinel, so a regression that
# starts echoing captured output -- including enabling xtrace around the login
# -- fails the suite rather than passing unnoticed.
#
# Everything here is offline and hermetic: ocm, oc and jq are replaced by mocks
# on PATH, and the test binary is replaced by a shell function (it is invoked by
# absolute path, so PATH cannot shadow it) preloaded through BASH_ENV. The
# command script itself is executed verbatim, never copied or rewritten, in a
# scrubbed environment. All identifiers below are fabricated.
#
# jq is mocked rather than inherited for two reasons: the validation image that
# runs the registry checks does not ship it, and the exit status for a parse
# error differs between jq releases (1.6 uses 4, 1.7 and later use 5). What is
# under test is that the step propagates and attributes that status, not which
# number jq chose, so the test picks it.
#
# Run directly:
#   hack/tests/rosa-e2e-test-commands_test.sh
#
# This test is not wired into hack/validate-registry-commands.sh, which
# hard-codes a single behavioural test; run it by hand when changing the
# command script.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/e2e/test/rosa-e2e-test-commands.sh"
TEST_ROOT=$(mktemp -d)

# A fabricated credential, planted in every credential fixture and in the
# stderr of the commands whose stderr the step discards.
FAKE_SECRET="NOT_A_REAL_TOKEN_000000"

# The status the mock jq reports for an unparseable response.
JQ_PARSE_STATUS=5

# Set by run_script.
CASE_DIR=""
OUTPUT=""
ARGV_LOG=""
STATUS=0

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] \
    || fail "${description}: expected exit status ${expected}, got ${actual}"
}

assert_contains() {
  local file="$1" expected="$2" description="$3"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,240p' "${file}" >&2
    fail "${description}: expected '${expected}' in ${file##*/}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2" description="$3"
  if grep -Fq -- "${unexpected}" "${file}"; then
    sed -n '1,240p' "${file}" >&2
    fail "${description}: did not expect '${unexpected}' in ${file##*/}"
  fi
}

assert_no_secrets() {
  local file="$1" description="$2"
  if grep -Fq -- "${FAKE_SECRET}" "${file}"; then
    fail "${description}: the step output leaked data from a credentialed command"
  fi
}

assert_no_junit() {
  local description="$1"
  [[ ! -e "${CASE_DIR}/artifacts/junit-rosa-e2e.xml" ]] \
    || fail "${description}: a JUnit report was produced even though the suite never ran"
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  # ocm mock. Behaviour is selected by MOCK_FAIL_CALL / MOCK_MALFORMED_CALL,
  # which name one of the OCM calls the step makes: hypershift (management
  # cluster name), search (management cluster id), cluster (api.listening) or
  # credentials (management cluster kubeconfig). Every invocation is recorded
  # so a test can assert what the step actually asked for.
  cat > "${mock_dir}/ocm" <<EOF
#!/bin/bash
leak_stderr() {
  echo "ERROR: request rejected" >&2
  echo "ERROR: Authorization: Bearer ${FAKE_SECRET}" >&2
}
EOF
  cat >> "${mock_dir}/ocm" <<'EOF'
echo "ocm $*" >> "${MOCK_ARGV_LOG}"

case "${1:-}" in
  login) echo "mock: ocm login ok" >&2; exit 0 ;;
  get) ;;
  *) echo "mock: unexpected ocm subcommand ${1:-}" >&2; exit 64 ;;
esac

case "${2:-}" in
  /api/clusters_mgmt/v1/clusters)     call=search ;;
  /api/clusters_mgmt/v1/clusters/*/hypershift)  call=hypershift ;;
  /api/clusters_mgmt/v1/clusters/*/credentials) call=credentials ;;
  /api/clusters_mgmt/v1/clusters/*)   call=cluster ;;
  *) echo "mock: unexpected ocm get path ${2:-}" >&2; exit 64 ;;
esac

[[ "${MOCK_FAIL_CALL:-}" == "${call}" ]] && { leak_stderr; exit 1; }
[[ "${MOCK_MALFORMED_CALL:-}" == "${call}" ]] && { echo "<html>not json</html>"; exit 0; }

case "${call}" in
  hypershift)
    if [[ "${MOCK_NO_MC:-}" == "true" ]]; then echo '{}'; else
      echo '{"management_cluster":"fake-mc-name","enabled":true}'
    fi
    ;;
  search)
    if [[ "${MOCK_EMPTY_MC_ID:-}" == "true" ]]; then echo '{"items":[]}'; else
      echo '{"items":[{"id":"fake-mc-id"}]}'
    fi
    ;;
  cluster)      printf '{"api":{"listening":"%s"}}\n' "${MOCK_LISTENING:-external}" ;;
  credentials)  printf '{"kubeconfig":"fake-kubeconfig-%s"}\n' "${MOCK_SECRET:-unset}" ;;
esac
exit 0
EOF

  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "whoami" ]] && exit "${MOCK_OC_WHOAMI_STATUS:-0}"
exit 0
EOF

  # jq stand-in covering only the four filters the step uses. Anything that is
  # not a JSON object is a parse error, reported with the status the test picked.
  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
filter=""
for arg in "$@"; do
  [[ "${arg}" == -* ]] || filter="${arg}"
done
input=$(cat)

# Empty input is not a parse error: jq produces nothing and succeeds, which is
# what lets a failed ocm call surface its own status through pipefail rather
# than the parser's.
[[ -n "${input}" ]] || exit 0

if [[ "${input}" != "{"* ]]; then
  echo "mock jq: parse error" >&2
  exit "${MOCK_JQ_PARSE_STATUS:-5}"
fi

# Prints the string value of the first occurrence of a key, or nothing, which
# is what the step's `// empty` filters produce for a missing value.
value() {
  grep -o "\"$1\":\"[^\"]*\"" <<<"${input}" | head -n 1 | sed -e 's/^[^:]*:"//' -e 's/"$//'
}

case "${filter}" in
  '.management_cluster // empty') value management_cluster ;;
  '.items[0].id // empty')        value id ;;
  '.api.listening // empty')      value listening ;;
  '.kubeconfig')                  value kubeconfig ;;
  *) echo "mock jq: unsupported filter ${filter}" >&2; exit 64 ;;
esac
exit 0
EOF

  # The step invokes the suite by absolute path, so PATH cannot shadow it.
  # BASH_ENV is read by the non-interactive shell that runs the command script,
  # which lets a function stand in for the binary. It unsets itself so the
  # mocks, which are themselves bash scripts, do not re-read it.
  cat > "${mock_dir}/bash_env.sh" <<'EOF'
unset BASH_ENV
function /usr/local/bin/e2e.test {
  echo "mock: e2e.test invoked with: $*"
  [[ -z "${ARTIFACT_DIR:-}" ]] || : > "${ARTIFACT_DIR}/junit-rosa-e2e.xml"
  return "${MOCK_SUITE_STATUS:-0}"
}
EOF

  chmod 0755 "${mock_dir}/ocm" "${mock_dir}/oc" "${mock_dir}/jq"
}

# has_fixture <spec> <name>
has_fixture() {
  [[ ",$1," == *",$2,"* ]]
}

# run_script <case-name> <fixture-spec> [VAR=VALUE ...]
#
# fixture-spec is a comma separated list, empty for the defaults:
#   no-cluster-id        omit ${SHARED_DIR}/cluster-id
#   no-ocm-credentials   omit every OCM credential
#   ocm-token            offline token instead of SSO client credentials
#   no-lease             omit LEASED_RESOURCE
#   provisioned          supply proxy-conf.sh, a kubeconfig and .awscred
#
# Runs the command script with fresh directories and a scrubbed environment, so
# the result never depends on the environment of whoever runs the test. Sets
# CASE_DIR, OUTPUT, ARGV_LOG and STATUS.
run_script() {
  local name="$1" fixtures="$2"
  shift 2

  CASE_DIR="${TEST_ROOT}/${name}"
  mkdir -p "${CASE_DIR}/shared" "${CASE_DIR}/profile" "${CASE_DIR}/artifacts" "${CASE_DIR}/bin"
  make_mocks "${CASE_DIR}/bin"
  OUTPUT="${CASE_DIR}/output"
  ARGV_LOG="${CASE_DIR}/ocm-argv"
  : > "${ARGV_LOG}"

  has_fixture "${fixtures}" no-cluster-id \
    || echo "fake-cluster-id" > "${CASE_DIR}/shared/cluster-id"

  # Credential fixtures carry the sentinel so assert_no_secrets is meaningful.
  if has_fixture "${fixtures}" ocm-token; then
    echo "fake-ocm-token-${FAKE_SECRET}" > "${CASE_DIR}/profile/ocm-token"
  elif ! has_fixture "${fixtures}" no-ocm-credentials; then
    echo "fake-sso-client-id-${FAKE_SECRET}"     > "${CASE_DIR}/profile/sso-client-id"
    echo "fake-sso-client-secret-${FAKE_SECRET}" > "${CASE_DIR}/profile/sso-client-secret"
  fi

  if has_fixture "${fixtures}" provisioned; then
    echo "export FAKE_PROXY_MARKER=applied" > "${CASE_DIR}/shared/proxy-conf.sh"
    echo "fake-provisioned-kubeconfig"      > "${CASE_DIR}/shared/kubeconfig"
    echo "aws_secret_access_key = ${FAKE_SECRET}" > "${CASE_DIR}/profile/.awscred"
  fi

  local lease=(LEASED_RESOURCE="fake-region")
  ! has_fixture "${fixtures}" no-lease || lease=()

  STATUS=0
  env -i \
    PATH="${CASE_DIR}/bin:${PATH}" \
    HOME="${CASE_DIR}" \
    BASH_ENV="${CASE_DIR}/bin/bash_env.sh" \
    SHARED_DIR="${CASE_DIR}/shared" \
    CLUSTER_PROFILE_DIR="${CASE_DIR}/profile" \
    ARTIFACT_DIR="${CASE_DIR}/artifacts" \
    OCM_LOGIN_ENV="staging" \
    REGION="" \
    LABEL_FILTER="" \
    CLUSTER_TOPOLOGY="" \
    EXCLUDE_CLUSTER_OPERATORS="" \
    MOCK_SECRET="${FAKE_SECRET}" \
    MOCK_ARGV_LOG="${ARGV_LOG}" \
    MOCK_JQ_PARSE_STATUS="${JQ_PARSE_STATUS}" \
    "${lease[@]}" \
    "$@" \
    bash "${COMMAND_SCRIPT}" > "${OUTPUT}" 2>&1 || STATUS=$?

  assert_no_secrets "${OUTPUT}" "${name}"
}

# A setup abort must name its stage, keep its status, never reach the suite and
# never leave a JUnit report behind. The expected statuses are the ones the
# script produced before the diagnostics existed: reporting must not change them.
assert_setup_failure() {
  local name="$1" expected_status="$2" stage="$3"
  assert_status "${STATUS}" "${expected_status}" "${name}"
  assert_contains "${OUTPUT}" "SETUP FAILED: stage=${stage} exit=${expected_status}" "${name}"
  assert_not_contains "${OUTPUT}" "e2e.test invoked" "${name}"
  assert_no_junit "${name}"
}

assert_suite_ran() {
  local name="$1"
  assert_contains "${OUTPUT}" "e2e.test invoked with: --ginkgo.junit-report=${CASE_DIR}/artifacts/junit-rosa-e2e.xml --ginkgo.v" "${name}"
  assert_not_contains "${OUTPUT}" "SETUP FAILED" "${name}"
}

test_success_with_management_cluster() {
  run_script success ""
  assert_status "${STATUS}" 0 "success"
  assert_contains "${OUTPUT}" "Management cluster access established" "success"
  assert_suite_ran "success"
  # The kubeconfig must be fetched for the management cluster, not the cluster
  # under test, and the search must be by name.
  assert_contains "${ARGV_LOG}" "ocm login --url staging --client-id" "success"
  assert_contains "${ARGV_LOG}" "ocm get /api/clusters_mgmt/v1/clusters/fake-cluster-id/hypershift" "success"
  assert_contains "${ARGV_LOG}" "--parameter search=name='fake-mc-name' --parameter size=1" "success"
  assert_contains "${ARGV_LOG}" "ocm get /api/clusters_mgmt/v1/clusters/fake-mc-id/credentials" "success"
}

test_provisioned_inputs_are_used() {
  run_script provisioned "provisioned"
  assert_status "${STATUS}" 0 "provisioned inputs"
  assert_contains "${OUTPUT}" "Private cluster detected, sourcing proxy configuration" "provisioned inputs"
  assert_contains "${OUTPUT}" "Using provisioned kubeconfig" "provisioned inputs"
  assert_not_contains "${OUTPUT}" "No AWS credentials found" "provisioned inputs"
  assert_suite_ran "provisioned inputs"
}

test_offline_token_login() {
  run_script ocm_token "ocm-token"
  assert_status "${STATUS}" 0 "offline token login"
  assert_contains "${OUTPUT}" "Logging into staging with offline token" "offline token login"
  assert_contains "${ARGV_LOG}" "ocm login --url staging --token" "offline token login"
  assert_suite_ran "offline token login"
}

test_no_management_cluster_still_runs_suite() {
  run_script no_mc "" MOCK_NO_MC=true
  assert_status "${STATUS}" 0 "no management cluster"
  assert_contains "${OUTPUT}" "No management cluster found" "no management cluster"
  assert_suite_ran "no management cluster"
}

test_unresolved_management_cluster_id_still_runs_suite() {
  run_script empty_mc_id "" MOCK_EMPTY_MC_ID=true
  assert_status "${STATUS}" 0 "unresolved management cluster id"
  assert_contains "${OUTPUT}" "Could not resolve management cluster ID" "unresolved management cluster id"
  assert_suite_ran "unresolved management cluster id"
}

test_internal_management_cluster_api_still_runs_suite() {
  run_script mc_internal "" MOCK_LISTENING=internal
  assert_status "${STATUS}" 0 "internal management cluster api"
  assert_contains "${OUTPUT}" "API is internal, skipping MC access" "internal management cluster api"
  assert_suite_ran "internal management cluster api"
}

test_unusable_management_cluster_kubeconfig_still_runs_suite() {
  run_script mc_kubeconfig_invalid "" MOCK_OC_WHOAMI_STATUS=1
  assert_status "${STATUS}" 0 "unusable management cluster kubeconfig"
  assert_contains "${OUTPUT}" "failed validation" "unusable management cluster kubeconfig"
  assert_suite_ran "unusable management cluster kubeconfig"
}

# The hypershift lookup is explicitly tolerated; only this one of the four OCM
# calls may fail without failing the step.
test_tolerated_hypershift_lookup_failure_still_runs_suite() {
  run_script tolerated_hypershift "" MOCK_FAIL_CALL=hypershift
  assert_status "${STATUS}" 0 "tolerated hypershift lookup failure"
  assert_contains "${OUTPUT}" "No management cluster found" "tolerated hypershift lookup failure"
  assert_suite_ran "tolerated hypershift lookup failure"
}

# test_fatal_lookup_failure <case> <mock-call> <stage>
test_fatal_lookup_failure() {
  local name="$1" call="$2" stage="$3"
  run_script "${name}" "" MOCK_FAIL_CALL="${call}"
  assert_setup_failure "${name}" 1 "${stage}"
  # These stages discard their stderr, so the diagnostic must say so rather
  # than send a triager looking for output that was never kept.
  assert_contains "${OUTPUT}" "discards its stderr on purpose" "${name}"
}

# test_malformed_response <case> <mock-call> <stage>
# The parse failure must propagate through pipefail and be attributed, with the
# status the parser reported rather than a flattened 1.
test_malformed_response() {
  local name="$1" call="$2" stage="$3"
  run_script "${name}" "" MOCK_MALFORMED_CALL="${call}"
  assert_setup_failure "${name}" "${JQ_PARSE_STATUS}" "${stage}"
}

test_missing_ocm_credentials() {
  run_script no_ocm_credentials "no-ocm-credentials"
  assert_setup_failure "no_ocm_credentials" 1 "ocm-login"
  assert_contains "${OUTPUT}" "No OCM credentials found" "no_ocm_credentials"
  # This stage printed its own cause, so the diagnostic must not claim the
  # error was discarded.
  assert_not_contains "${OUTPUT}" "discards its stderr" "no_ocm_credentials"
}

test_missing_cluster_id() {
  run_script no_cluster_id "no-cluster-id"
  assert_setup_failure "no_cluster_id" 1 "cluster-id"
  assert_not_contains "${OUTPUT}" "discards its stderr" "no_cluster_id"
}

# Without a lease, the first use of LEASED_RESOURCE aborts under nounset. Which
# statement that is depends on whether AWS credentials were present, and the
# reported stage must follow it rather than name whatever came before.
test_missing_lease_without_aws_credentials() {
  run_script no_lease "no-lease"
  assert_setup_failure "no_lease" 1 "exports"
}

test_missing_lease_with_aws_credentials() {
  run_script no_lease_provisioned "provisioned,no-lease"
  assert_setup_failure "no_lease_provisioned" 1 "aws-config"
}

# test_suite_failure_is_reported_unchanged <status>
# A failing suite is not a setup failure: the status passes through and the
# diagnostic stays quiet so the suite's own report is what a reader sees.
test_suite_failure_is_reported_unchanged() {
  local expected="$1"
  run_script "suite_failure_${expected}" "" MOCK_SUITE_STATUS="${expected}"
  assert_status "${STATUS}" "${expected}" "suite failure ${expected}"
  assert_contains "${OUTPUT}" "e2e.test invoked" "suite failure ${expected}"
  assert_not_contains "${OUTPUT}" "SETUP FAILED" "suite failure ${expected}"
}

test_success_with_management_cluster
test_provisioned_inputs_are_used
test_offline_token_login
test_no_management_cluster_still_runs_suite
test_unresolved_management_cluster_id_still_runs_suite
test_internal_management_cluster_api_still_runs_suite
test_unusable_management_cluster_kubeconfig_still_runs_suite
test_tolerated_hypershift_lookup_failure_still_runs_suite
test_fatal_lookup_failure fail_mc_lookup_id    search      mc-lookup-id
test_fatal_lookup_failure fail_mc_listening    cluster     mc-api-listening
test_fatal_lookup_failure fail_mc_credentials  credentials mc-credentials
test_malformed_response   bad_mc_lookup_id     search      mc-lookup-id
test_malformed_response   bad_mc_listening     cluster     mc-api-listening
test_malformed_response   bad_mc_credentials   credentials mc-credentials
test_missing_ocm_credentials
test_missing_cluster_id
test_missing_lease_without_aws_credentials
test_missing_lease_with_aws_credentials
test_suite_failure_is_reported_unchanged 1
test_suite_failure_is_reported_unchanged 3

echo "PASS: rosa-e2e-test setup stage diagnostics tests"
