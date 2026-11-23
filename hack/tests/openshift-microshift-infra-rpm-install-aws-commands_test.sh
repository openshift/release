#!/bin/bash

# Behavioral tests for the rebase decision in the MicroShift AWS RPM-install step
# (ci-operator/step-registry/openshift/microshift/infra/rpm-install-aws).
#
# These tests intentionally live outside the step registry because registry
# validation only accepts registered step files. They are wired into
# hack/validate-registry-commands.sh, which also shellchecks this file.
#
# The test extracts the self-contained determine_rebase_to function from the
# command script (between its "determine_rebase_to BEGIN/END" markers), sources
# it, and exercises every decision branch:
#   * controller / release-payload verification path (unchanged),
#   * default periodic / presubmit path with no rebase (unchanged),
#   * explicit opt-in manual retest with a valid exact amd64 nightly,
#   * explicit opt-in with missing or untrusted input (fail closed).

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/openshift/microshift/infra/rpm-install-aws/openshift-microshift-infra-rpm-install-aws-commands.sh"
REF_FILE="${SCRIPT_DIR}/../../ci-operator/step-registry/openshift/microshift/infra/rpm-install-aws/openshift-microshift-infra-rpm-install-aws-ref.yaml"

PASS_COUNT=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Extract and source only the determine_rebase_to block so the surrounding
# script (ssh/scp, remote install, ci-functions) is never executed.
BLOCK=$(awk '
  /# >>> determine_rebase_to BEGIN/ { capture = 1; next }
  /# <<< determine_rebase_to END/   { capture = 0 }
  capture { print }
' "${COMMAND_SCRIPT}")

if ! grep -q 'determine_rebase_to()' <<<"${BLOCK}"; then
  fail "could not extract determine_rebase_to from ${COMMAND_SCRIPT}"
fi

# shellcheck disable=SC1090
source <(echo "${BLOCK}")

# run_case runs determine_rebase_to with a controlled environment and captures
# stdout and the return code. Every input is passed explicitly so a case never
# leaks environment from another.
REBASE_OUT=""
REBASE_RC=0
run_case() {
  local opt_in="$1" job_spec="$2" release_latest="$3" original="$4"
  if REBASE_OUT=$(
      MULTISTAGE_PARAM_OVERRIDE_MICROSHIFT_EXACT_PAYLOAD_RETEST="${opt_in}" \
      JOB_SPEC="${job_spec}" \
      RELEASE_IMAGE_LATEST="${release_latest}" \
      ORIGINAL_RELEASE_IMAGE_LATEST="${original}" \
      determine_rebase_to 2>/dev/null
    ); then
    REBASE_RC=0
  else
    REBASE_RC=$?
  fi
}

assert_rebase() {
  local description="$1" expected_target="$2"
  [[ "${REBASE_RC}" == "0" ]] || fail "${description}: expected rebase (rc 0), got rc ${REBASE_RC}"
  [[ "${REBASE_OUT}" == "${expected_target}" ]] || fail "${description}: expected target '${expected_target}', got '${REBASE_OUT}'"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_no_rebase() {
  local description="$1"
  [[ "${REBASE_RC}" == "0" ]] || fail "${description}: expected success (rc 0), got rc ${REBASE_RC}"
  [[ -z "${REBASE_OUT}" ]] || fail "${description}: expected no rebase target, got '${REBASE_OUT}'"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_fail_closed() {
  local description="$1"
  [[ "${REBASE_RC}" != "0" ]] || fail "${description}: expected fail-closed (non-zero rc), got rc 0 with '${REBASE_OUT}'"
  [[ -z "${REBASE_OUT}" ]] || fail "${description}: fail-closed must not emit a rebase target, got '${REBASE_OUT}'"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# Canonical in-cluster target reused for the rebase (as ci-operator exports it).
IN_CLUSTER="registry.build01.ci.openshift.org/ci-op-abcd1234/release@sha256:deadbeef"
# Canonical external, human-readable exact amd64 OCP 4.21 nightly.
EXACT_4_21="registry.ci.openshift.org/ocp/release:4.21.0-0.nightly-2026-11-23-122932"
# The two MicroShift 4.21 amd64 conformance job names this feature targets.
JOB_PARALLEL="periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance"
JOB_SERIAL="periodic-ci-openshift-microshift-release-4.21-periodics-e2e-aws-ovn-ocp-conformance-serial"
# A controller / payload prowjobid contains the candidate version and "nightly".
CONTROLLER_SPEC='{"job":"'"${JOB_PARALLEL}"'","prowjobid":"4.21.0-0.nightly-2026-11-23-122932-aws-ovn-conformance"}'
# A manual run always has a UUID prowjobid.
UUID_SPEC_PARALLEL='{"job":"'"${JOB_PARALLEL}"'","prowjobid":"0f8e2a1c-1234-4abc-9def-0123456789ab"}'
UUID_SPEC_SERIAL='{"job":"'"${JOB_SERIAL}"'","prowjobid":"0f8e2a1c-1234-4abc-9def-0123456789ab"}'

# --- Controller / release-payload verification path (must stay unchanged) -----

run_case "false" "${CONTROLLER_SPEC}" "${IN_CLUSTER}" "${EXACT_4_21}"
assert_rebase "controller run (prowjobid has nightly) rebases" "${IN_CLUSTER}"

# Controller path takes precedence over the opt-in switch and is not affected by
# the explicit-path validation (even with an unset ORIGINAL pullspec).
run_case "true" "${CONTROLLER_SPEC}" "${IN_CLUSTER}" ""
assert_rebase "controller run wins over opt-in and skips explicit validation" "${IN_CLUSTER}"

# --- Default periodic / presubmit path (no rebase, unchanged) -----------------

run_case "false" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" "${EXACT_4_21}"
assert_no_rebase "scheduled periodic (UUID, opt-in off) does not rebase"

# --- Explicit opt-in manual retest, valid input -------------------------------

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" "${EXACT_4_21}"
assert_rebase "explicit retest of parallel job rebases to in-cluster target" "${IN_CLUSTER}"

run_case "true" "${UUID_SPEC_SERIAL}" "${IN_CLUSTER}" "${EXACT_4_21}"
assert_rebase "explicit retest of serial job rebases to in-cluster target" "${IN_CLUSTER}"

# --- Explicit opt-in manual retest, invalid input (fail closed) ---------------

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" ""
assert_fail_closed "opt-in with missing ORIGINAL_RELEASE_IMAGE_LATEST fails closed"

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" \
  "registry.ci.openshift.org/ocp-arm64/release-arm64:4.21.0-0.nightly-2026-11-23-122932"
assert_fail_closed "opt-in with an arm64 pullspec fails closed (amd64 only)"

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" \
  "registry.ci.openshift.org/ocp/release:4.20.0-0.nightly-2026-11-23-122932"
assert_fail_closed "opt-in with a different release line than the job fails closed"

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" \
  "quay.io/openshift-release-dev/ocp-release:4.21.0-0.nightly-2026-11-23-122932"
assert_fail_closed "opt-in with an untrusted registry fails closed"

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" \
  "registry.ci.openshift.org/ocp/release:4.21.0-0.ci-2026-11-23-122932"
assert_fail_closed "opt-in with a ci (non-nightly) stream fails closed"

run_case "true" "${UUID_SPEC_PARALLEL}" "${IN_CLUSTER}" \
  "registry.ci.openshift.org/ocp/release@sha256:0123456789abcdef"
assert_fail_closed "opt-in with a digest instead of the nightly tag fails closed"

run_case "true" '{"job":"some-manual-job-without-release","prowjobid":"uuid"}' \
  "${IN_CLUSTER}" "${EXACT_4_21}"
assert_fail_closed "opt-in on a job whose name lacks a release line fails closed"

run_case "true" "${UUID_SPEC_PARALLEL}" "" "${EXACT_4_21}"
assert_fail_closed "opt-in with an unset RELEASE_IMAGE_LATEST fails closed"

# --- Static guardrails on the step contract -----------------------------------

grep -Eq '^\s*-\s*name:\s*MULTISTAGE_PARAM_OVERRIDE_MICROSHIFT_EXACT_PAYLOAD_RETEST\s*$' "${REF_FILE}" \
  || fail "ref must declare the MULTISTAGE_PARAM_OVERRIDE_MICROSHIFT_EXACT_PAYLOAD_RETEST parameter"
PASS_COUNT=$((PASS_COUNT + 1))

# The opt-in must default to off so automated runs are untouched.
awk '
  /name: MULTISTAGE_PARAM_OVERRIDE_MICROSHIFT_EXACT_PAYLOAD_RETEST/ { found = 1; next }
  found { print; exit }
' "${REF_FILE}" | grep -Eq 'default:\s*"false"' \
  || fail "the opt-in parameter must default to \"false\""
PASS_COUNT=$((PASS_COUNT + 1))

echo "PASS: ${PASS_COUNT} determine_rebase_to assertions"
