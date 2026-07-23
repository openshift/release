#!/bin/bash

# ==============================================================================
# Operator Scorecard Test Script
#
# This script runs Operator SDK scorecard tests for the Sail Operator
# to validate operator best practices and functionality.
#
# It performs the following steps:
# 1. Starts scorecard tests detached inside the builder pod (no long-lived
#    oc rsh WebSocket), then polls done/RC markers with short oc exec.
# 2. Configures the test environment with the appropriate kubeconfig and
#    working directory within the test pod.
# 3. Runs the scorecard test suite using the configured test command,
#    with container-free builds for compatibility.
# 4. Collects test artifacts and reports from the test pod execution.
# 5. Copies all generated artifacts to the local artifact directory for
#    CI pipeline consumption and analysis.
#
# Required Environment Variables:
#   - MAISTRA_NAMESPACE: The namespace where the test pod is running.
#   - MAISTRA_SC_POD: The name of the test pod executing the scorecard tests.
#   - ARTIFACT_DIR: The local directory to store test artifacts and reports.
#
# Optional Environment Variables:
#   - SCORECARD_COMMAND: Custom scorecard test command (default: make test.scorecard).
#
# Notes:
#   - The scorecard tests validate operator compliance with OLM best practices.
#   - Tests run with BUILD_WITH_CONTAINER="0" for compatibility with the CI environment.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

readonly POLL_INTERVAL=15
readonly DONE_MARKER=/tmp/TESTS_DONE
readonly RC_MARKER=/tmp/TESTS_RC
readonly TEST_LOG=/tmp/test-run.log
readonly RUNNER_SCRIPT=/tmp/run-sail-scorecard-tests.sh

pod_exec() {
  oc exec -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" -- "$@"
}

clear_test_markers() {
  pod_exec sh -c "rm -f '${DONE_MARKER}' '${RC_MARKER}' '${TEST_LOG}' '${RUNNER_SCRIPT}'" || true
}

are_tests_done() {
  echo "Checking for ${DONE_MARKER} and ${RC_MARKER}"
  pod_exec sh -c "test -f '${DONE_MARKER}' && test -f '${RC_MARKER}'"
}

read_test_rc() {
  pod_exec sh -c "tr -d '[:space:]' < '${RC_MARKER}'"
}

# Dump the complete detached suite log into the Prow build log and ARTIFACT_DIR
# once the run finishes (success or failure).
dump_full_test_log() {
  echo "================================================================"
  echo "BEGIN full detached test log (${TEST_LOG})"
  echo "================================================================"
  if pod_exec sh -c "test -f '${TEST_LOG}'"; then
    pod_exec cat "${TEST_LOG}" || true
    mkdir -p "${ARTIFACT_DIR}"
    oc cp "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:${TEST_LOG}" "${ARTIFACT_DIR}/detached-test-run.log" || true
    echo "Full detached test log also saved to ${ARTIFACT_DIR}/detached-test-run.log"
  else
    echo "WARNING: ${TEST_LOG} not found in ${MAISTRA_SC_POD}; nothing to dump"
  fi
  echo "================================================================"
  echo "END full detached test log"
  echo "================================================================"
}

wait_for_tests() {
  echo "Polling for detached scorecard completion (${DONE_MARKER} + ${RC_MARKER})..."
  local poll_failures=0
  local max_consecutive_poll_failures=20

  while true; do
    if are_tests_done; then
      echo "Detached scorecard finished (markers present)."
      return 0
    fi

    if pod_exec sh -c "true" >/dev/null 2>&1; then
      poll_failures=0
      echo "Detached tests still running; waiting for ${DONE_MARKER} + ${RC_MARKER}..."
    else
      poll_failures=$((poll_failures + 1))
      echo "WARNING: short oc exec failed while polling (${poll_failures}/${max_consecutive_poll_failures}). Will retry."
      if [ "${poll_failures}" -ge "${max_consecutive_poll_failures}" ]; then
        echo "ERROR: too many consecutive poll failures talking to ${MAISTRA_SC_POD}" >&2
        return 1
      fi
    fi

    sleep "${POLL_INTERVAL}"
  done
}

start_detached_tests() {
  clear_test_markers

  local local_runner
  local_runner="$(mktemp)"
  cat > "${local_runner}" <<EOF
#!/bin/bash
set +e
export KUBECONFIG=/work/ci-kubeconfig
export BUILD_WITH_CONTAINER="0"
cd /work
entrypoint ${SCORECARD_COMMAND:-make test.scorecard}
rc=\$?
echo "\$rc" > ${RC_MARKER}
touch ${DONE_MARKER}
exit "\$rc"
EOF

  echo "Copying detached runner into ${MAISTRA_SC_POD}:${RUNNER_SCRIPT}"
  oc cp "${local_runner}" "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:${RUNNER_SCRIPT}"
  rm -f "${local_runner}"
  pod_exec chmod +x "${RUNNER_SCRIPT}"

  echo "Starting detached scorecard suite in ${MAISTRA_SC_POD}..."
  pod_exec sh -c "nohup '${RUNNER_SCRIPT}' > '${TEST_LOG}' 2>&1 < /dev/null & echo \"Started PID \$!\""
}

echo "Starting scorecard test execution in pod ${MAISTRA_SC_POD}..."

set +o errexit
start_detached_tests
if ! wait_for_tests; then
  echo "ERROR: failed while waiting for detached scorecard tests" >&2
  dump_full_test_log
  exit 1
fi
TEST_RC="$(read_test_rc)"
dump_full_test_log
set -o errexit

echo "Copying artifacts from test pod..."
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}" || true

echo "Scorecard test execution completed with exit code: ${TEST_RC}"
exit "${TEST_RC}"
