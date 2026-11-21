#!/bin/bash
# Behavior tests for the baremetalds-e2e-bgp-vip-verify step.
#
# Run locally with:
#   bash hack/tests/baremetalds-e2e-bgp-vip-verify-commands_test.sh
#
# The step script runs unmodified against fake ssh and openshift-tests
# executables, covering how the bash checks and the origin suites combine into
# the step result. It needs only bash, coreutils, grep, sed and awk and runs in
# the step-registry-shellcheck presubmit through hack/validate-registry-commands.sh.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
STEP_DIR="${REPO_ROOT}/ci-operator/step-registry/baremetalds/e2e/bgp-vip/verify"
COMMAND_SCRIPT="${STEP_DIR}/baremetalds-e2e-bgp-vip-verify-commands.sh"
REF_FILE="${STEP_DIR}/baremetalds-e2e-bgp-vip-verify-ref.yaml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

BGP_VIP=openshift/bgp-vip
BGP_VIP_DISRUPTIVE=openshift/bgp-vip/disruptive
OTHER_SUITE=openshift/conformance/parallel

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ref_default <name>: the double-quoted default of an env entry in the ref.
ref_default() {
  awk -v name="$1" '
    $1 == "-" && $2 == "name:" { in_entry = ($3 == name); next }
    in_entry && $1 == "default:" {
      value = $0
      if (!sub(/^[[:space:]]*default:[[:space:]]*"/, "", value) || !sub(/"[[:space:]]*$/, "", value)) {
        exit
      }
      print value
      found = 1
      exit
    }
    END { exit !found }
  ' "${REF_FILE}" || fail "no double-quoted default for $1 in ${REF_FILE}"
}

DEFAULT_SUITES=$(ref_default BGP_VIP_ORIGIN_SUITES)
DEFAULT_MONITORS=$(ref_default BGP_VIP_ORIGIN_DISABLED_MONITORS)
[[ "${DEFAULT_SUITES}" == "${BGP_VIP} ${BGP_VIP_DISRUPTIVE}" ]] || fail "unexpected BGP_VIP_ORIGIN_SUITES default '${DEFAULT_SUITES}'"
[[ -n "${DEFAULT_MONITORS}" ]] || fail "BGP_VIP_ORIGIN_DISABLED_MONITORS default is empty"

make_fixture() {
  local case_dir="$1"
  mkdir -p "${case_dir}/bin" "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/profile" "${case_dir}/home" "${case_dir}/state"
  touch "${case_dir}/state/calls"
  printf 'fixture-key\n' > "${case_dir}/profile/packet-ssh-key"
  cat > "${case_dir}/shared/packet-conf.sh" <<'EOF'
IP=192.0.2.10
PORT=22
SSHOPTS=(-o 'StrictHostKeyChecking=no' -i "${CLUSTER_PROFILE_DIR}/packet-ssh-key")
EOF
  printf 'export DS_IP_STACK=v4\n' > "${case_dir}/shared/ds-vars.conf"

  # The bash checks run on the hypervisor through ssh; keep the script they
  # receive and report the configured result.
  cat > "${case_dir}/bin/ssh" <<'EOF'
#!/bin/bash
cat > "${MOCK_STATE_DIR}/ssh-stdin"
printf 'ssh %s\n' "$*" >> "${MOCK_STATE_DIR}/calls"
exit "${MOCK_SSH_RC}"
EOF

  # "openshift-tests run" for a suite the binary does not ship fails the way
  # openshift/origin does: the available suites and the error on stderr, exit 1.
  # Anything but "run" (e.g. "list suites") is unexpected.
  cat > "${case_dir}/bin/openshift-tests" <<'EOF'
#!/bin/bash
printf 'openshift-tests %s\n' "$*" >> "${MOCK_STATE_DIR}/calls"
if [[ "${1:-}" != run ]]; then
  echo "fixture: unexpected openshift-tests invocation: $*" >&2
  exit 2
fi
shipped=false
for suite in ${MOCK_SHIPPED_SUITES}; do
  [[ "${suite}" == "$2" ]] && shipped=true
done
if [[ "${shipped}" != true ]]; then
  printf 'Select a test suite to run against the server:\n\n' >&2
  printf '%s\n' ${MOCK_SHIPPED_SUITES} >&2
  printf 'error: suite "%s" does not exist\n' "$2" >&2
  exit 1
fi
for failing in ${MOCK_FAILING_SUITES}; do
  if [[ "${failing}" == "$2" ]]; then
    echo "fixture: suite $2 failed"
    exit 1
  fi
done
EOF
  chmod +x "${case_dir}/bin/ssh" "${case_dir}/bin/openshift-tests"
}

# run_case <name> [VAR=value ...]: runs the step; leaves CASE_DIR and CASE_RC.
# VARs: SSH_RC, SHIPPED, FAILING, SUITES.
run_case() {
  local name="$1"; shift
  local SSH_RC=0 SHIPPED="${OTHER_SUITE} ${BGP_VIP} ${BGP_VIP_DISRUPTIVE}" FAILING="" SUITES="${DEFAULT_SUITES}"
  local assignment
  for assignment in "$@"; do
    case "${assignment%%=*}" in
      SSH_RC|SHIPPED|FAILING|SUITES) local "${assignment}" ;;
      *) fail "unknown run_case variable ${assignment}" ;;
    esac
  done
  CASE_DIR="${TEST_ROOT}/${name}"
  make_fixture "${CASE_DIR}"
  CASE_RC=0
  (
    export SHARED_DIR="${CASE_DIR}/shared" ARTIFACT_DIR="${CASE_DIR}/artifacts"
    export CLUSTER_PROFILE_DIR="${CASE_DIR}/profile" HOME="${CASE_DIR}/home"
    export PATH="${CASE_DIR}/bin:${PATH}" MOCK_STATE_DIR="${CASE_DIR}/state"
    export MOCK_SSH_RC="${SSH_RC}" MOCK_SHIPPED_SUITES="${SHIPPED}" MOCK_FAILING_SUITES="${FAILING}"
    export BGP_VIP_ORIGIN_SUITES="${SUITES}" BGP_VIP_ORIGIN_DISABLED_MONITORS="${DEFAULT_MONITORS}"
    bash "${COMMAND_SCRIPT}"
  ) > "${CASE_DIR}/output.log" 2>&1 || CASE_RC=$?
}

show_case() {
  echo "--- ${CASE_DIR}/output.log" >&2
  cat "${CASE_DIR}/output.log" >&2
  echo "--- ${CASE_DIR}/state/calls" >&2
  cat "${CASE_DIR}/state/calls" >&2
}

# case_fail <message>: dump the current case and fail with its name.
case_fail() {
  show_case
  fail "${CASE_DIR##*/}: $*"
}

expect_rc() {
  [[ "${CASE_RC}" == "$1" ]] || case_fail "expected exit $1, got ${CASE_RC}"
}

expect_output() {
  grep -Fq -- "$1" "${CASE_DIR}/output.log" || case_fail "expected output '$1'"
}

expect_no_output() {
  if grep -Fq -- "$1" "${CASE_DIR}/output.log"; then case_fail "unexpected output '$1'"; fi
}

# expect_runs [suite ...]: exactly these suites were run, in this order, and
# openshift-tests was never asked for anything else (no suite discovery).
expect_runs() {
  local expected="" actual
  if [[ "$#" -ne 0 ]]; then expected=$(printf '%s\n' "$@"); fi
  actual=$(sed -n 's/^openshift-tests run \([^ ]*\) .*/\1/p' "${CASE_DIR}/state/calls")
  [[ "${actual}" == "${expected}" ]] || case_fail "expected suite runs [$*], got [$(tr '\n' ' ' <<<"${actual}")]"
  if grep '^openshift-tests ' "${CASE_DIR}/state/calls" | grep -qv '^openshift-tests run '; then
    case_fail "openshift-tests was called for something other than run"
  fi
}

# The bash checks still run first, once, with the full remote script.
expect_checks_ran() {
  local actual
  actual=$(grep -c '^ssh ' "${CASE_DIR}/state/calls" || true)
  [[ "${actual}" == 1 ]] || case_fail "expected the checks to run once over ssh, got ${actual}"
  [[ "$(sed -n 1p "${CASE_DIR}/state/calls")" == ssh\ * ]] || case_fail "the checks did not run first"
  local check
  for check in '[1/6]' '[2/6]' '[3/6]' '[4/6]' '[5/6]' '[6/6]' 'BGP VIP verification passed'; do
    grep -Fq -- "${check}" "${CASE_DIR}/state/ssh-stdin" || case_fail "remote checks script lacks '${check}'"
  done
}

PASSED=0
pass() {
  PASSED=$((PASSED + 1))
  echo "PASS: $1"
}

test_all_suites_pass() {
  run_case all-pass
  expect_rc 0
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  local run_args arg
  run_args=$(grep "^openshift-tests run ${BGP_VIP} " "${CASE_DIR}/state/calls")
  for arg in '--provider {"type":"baremetal"}' '"hypervisorIP":"192.0.2.10"' "\"privateKeyPath\":\"${CASE_DIR}/profile/packet-ssh-key\"" \
    "--disable-monitor ${DEFAULT_MONITORS}" "-o ${CASE_DIR}/artifacts/openshift_bgp-vip/e2e.log" "--junit-dir ${CASE_DIR}/artifacts/openshift_bgp-vip/junit"; do
    [[ "${run_args}" == *"${arg}"* ]] || case_fail "run arguments lack '${arg}'"
  done
  expect_no_output "failed"
  pass "all suites pass: checks and both suites run directly, step passes"
}

test_unknown_suite() {
  # The payload ships only the disruptive suite: openshift-tests rejects the
  # other one itself, and the next suite still runs.
  run_case unknown-suite SHIPPED="${OTHER_SUITE} ${BGP_VIP_DISRUPTIVE}"
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "error: suite \"${BGP_VIP}\" does not exist"
  expect_no_output "error: suite \"${BGP_VIP_DISRUPTIVE}\" does not exist"
  expect_output "BGP VIP origin suites failed"
  expect_no_output "verification checks failed"
  pass "a suite the payload does not ship fails the step with openshift-tests' own error"
}

test_no_suite_shipped() {
  # A payload whose openshift-tests predates both suites.
  run_case no-suite-shipped SHIPPED="${OTHER_SUITE}"
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "error: suite \"${BGP_VIP}\" does not exist"
  expect_output "error: suite \"${BGP_VIP_DISRUPTIVE}\" does not exist"
  expect_output "BGP VIP origin suites failed"
  pass "a payload shipping neither suite fails the step; both runs are attempted"
}

test_suite_failure() {
  run_case suite-failure FAILING="${BGP_VIP}"
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "fixture: suite ${BGP_VIP} failed"
  expect_output "BGP VIP origin suites failed"
  expect_no_output "verification checks failed"
  pass "a failed suite fails the step; the next suite still runs"
}

test_checks_fail_suites_still_run() {
  # 255 is what ssh itself returns when it cannot run the checks.
  run_case checks-fail SSH_RC=255
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP verification checks failed (exit 255)"
  expect_no_output "origin suites failed"
  pass "failed bash checks fail the step; both suites still run"
}

test_checks_and_suite_fail() {
  # The first suite fails, so the second one must still run.
  run_case checks-and-suite-fail SSH_RC=1 FAILING="${BGP_VIP}"
  expect_rc 1
  expect_checks_ran
  expect_runs "${BGP_VIP}" "${BGP_VIP_DISRUPTIVE}"
  expect_output "BGP VIP verification checks failed (exit 1)"
  expect_output "BGP VIP origin suites failed"
  pass "check and suite failures are both reported"
}

test_checks_only() {
  run_case checks-only SUITES=""
  expect_rc 0
  expect_checks_ran
  expect_runs
  pass "BGP_VIP_ORIGIN_SUITES=\"\" runs the checks only"
}

[[ "$#" -eq 0 ]] || fail "usage: $0"

test_all_suites_pass
test_unknown_suite
test_no_suite_shipped
test_suite_failure
test_checks_fail_suites_still_run
test_checks_and_suite_fail
test_checks_only

echo "PASS: baremetalds-e2e-bgp-vip-verify tests (${PASSED} passed)"
