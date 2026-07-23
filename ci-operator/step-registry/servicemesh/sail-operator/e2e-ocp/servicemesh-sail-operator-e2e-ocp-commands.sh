#!/bin/bash

# ==============================================================================
# E2E Test Runner Script
#
# This script runs end-to-end tests for E2E in an OpenShift cluster.
#
# It performs the following steps:
# 1. Verifies the internal OCP image registry is running. If not, it creates
#    the default route.
# 2. Waits for all ClusterOperators to become stable before starting tests.
# 3. Starts the e2e suite detached inside the builder pod (no long-lived oc rsh),
#    then polls done/RC markers with short oc exec sessions.
# 4. Collects test artifacts (like JUnit reports).
# 5. Retries when completion markers or JUnit reports are missing.
# 6. Validates that test reports were generated and exits with the test status.
#
# Required Environment Variables:
#   - OCP: Set to "true" for OpenShift clusters.
#   - MAISTRA_NAMESPACE: The namespace where the test pod is running.
#   - MAISTRA_SC_POD: The name of the test pod.
#   - ARTIFACT_DIR: The local directory to store test artifacts.
#   - VERSIONS_YAML_CONFIG (optional): Path to versions YAML config.
#   - E2E_COMMAND (optional): Replace with the specific test command to run.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

# --- Configuration ---
readonly RETRY_SLEEP_INTERVAL=30
readonly POLL_INTERVAL=30
readonly LOG_TAIL_LINES=80
readonly DONE_MARKER=/tmp/TESTS_DONE
readonly RC_MARKER=/tmp/TESTS_RC
readonly TEST_LOG=/tmp/test-run.log
readonly RUNNER_SCRIPT=/tmp/run-sail-e2e-tests.sh

# --- Functions ---

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

tail_test_log() {
  pod_exec sh -c "if [ -f '${TEST_LOG}' ]; then echo '--- test log (last ${LOG_TAIL_LINES} lines) ---'; tail -n ${LOG_TAIL_LINES} '${TEST_LOG}'; fi" || true
}

# Dump the complete detached suite log into the Prow build log and ARTIFACT_DIR.
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
  echo "Polling for detached test completion (${DONE_MARKER} + ${RC_MARKER})..."
  local poll_failures=0
  local max_consecutive_poll_failures=20

  while true; do
    if are_tests_done; then
      echo "Detached tests finished (markers present)."
      return 0
    fi

    if pod_exec sh -c "true" >/dev/null 2>&1; then
      poll_failures=0
      tail_test_log
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

# collect_oom_debug_info gathers debugging information when a pod exits with 137 (OOM/SIGKILL).
# This helps determine if the pod was killed due to pod limits or node-level OOM.
collect_oom_debug_info() {
  echo "=== OOM DEBUG INFO: Collecting diagnostics for exit code 137 ==="

  echo "--- Pod description for ${MAISTRA_SC_POD} ---"
  oc describe pod "${MAISTRA_SC_POD}" -n "${MAISTRA_NAMESPACE}" 2>&1 || echo "Failed to describe pod"

  local node_name
  node_name=$(oc get pod "${MAISTRA_SC_POD}" -n "${MAISTRA_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")

  echo "--- Events from namespace ${MAISTRA_NAMESPACE} ---"
  oc get events -n "${MAISTRA_NAMESPACE}" --sort-by='.lastTimestamp' 2>&1 || echo "Failed to get namespace events"

  if [[ -n "${node_name}" ]]; then
    echo "--- Node ${node_name} description ---"
    oc describe node "${node_name}" 2>&1 || echo "Failed to describe node"

    echo "--- Events from node ${node_name} ---"
    oc get events --field-selector "involvedObject.name=${node_name}" --all-namespaces --sort-by='.lastTimestamp' 2>&1 || echo "Failed to get node events"

    echo "--- All pods on node ${node_name} with resource usage ---"
    oc adm top pods --all-namespaces --selector="spec.nodeName=${node_name}" 2>&1 || echo "Failed to get pod metrics (metrics-server may not be available)"
    oc get pods --all-namespaces --field-selector "spec.nodeName=${node_name}" -o wide 2>&1 || echo "Failed to list pods on node"
  else
    echo "WARNING: Could not determine node name for pod ${MAISTRA_SC_POD}"
  fi

  echo "=== END OOM DEBUG INFO ==="
}

# check_cluster_operators waits up to 15 minutes for all OpenShift cluster
# operators to be in a stable (not Progressing, not Degraded, and Available) state.
check_cluster_operators() {
  if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for the cluster operator health check. Please install jq." >&2
    exit 1
  fi

  local timeout_seconds=900
  local required_stable_checks=4
  local sleep_interval=15

  echo "Validating OpenShift cluster operators are stable..."
  echo "Requirement: Status must be stable for $required_stable_checks consecutive checks (with $sleep_interval second intervals)."

  local end_time=$(( $(date +%s) + timeout_seconds ))
  local stable_checks_count=0

  while [ "$(date +%s)" -lt $end_time ]; do
    local oc_output
    if ! oc_output=$(oc get clusteroperator -o json); then
      echo "Warning: API connection dropped, retrying in next loop..." >&2
      stable_checks_count=0
      sleep "$sleep_interval"
      continue
    fi

    local unstable_operators_json
    if ! unstable_operators_json=$(echo "$oc_output" | jq -r '[.items[] | select(.status.conditions[] | (.type == "Available" and .status == "False") or (.type == "Progressing" and .status == "True") or (.type == "Degraded" and .status == "True")) | .metadata.name]'); then
      echo "Warning: Failed to parse cluster operator JSON, retrying in next loop..." >&2
      stable_checks_count=0
      sleep "$sleep_interval"
      continue
    fi

    if [[ $(echo "$unstable_operators_json" | jq 'length') -eq 0 ]]; then
      stable_checks_count=$((stable_checks_count + 1))
      echo "Stability check #${stable_checks_count} passed. ($stable_checks_count/$required_stable_checks)"

      if [[ $stable_checks_count -ge $required_stable_checks ]]; then
        echo "All cluster operators are stable. Proceeding."
        return 0
      fi
    else
      echo "Cluster operators are not stable. Unstable: $(echo "$unstable_operators_json" | jq -r '. | join(", ")')"
      echo "Resetting stability count."
      stable_checks_count=0
    fi

    sleep "$sleep_interval"
  done

  echo "ERROR: Timeout of $timeout_seconds seconds reached. Not all cluster operators became stable." >&2
  oc get clusteroperator
  exit 1
}

start_detached_tests() {
  clear_test_markers

  local local_runner
  local_runner="$(mktemp)"
  # Quay credentials are written only into the in-pod runner (same trust boundary as
  # the previous oc rsh invocation). Do not echo them from this step script.
  cat > "${local_runner}" <<EOF
#!/bin/bash
set +e
docker login -u="${QUAY_USERNAME}" -p="${QUAY_PASSWORD}" quay.io
export KUBECONFIG=/work/ci-kubeconfig
export BUILD_WITH_CONTAINER="0"
export CI="${CI:-true}"
export HUB="${HUB:-quay.io/sail-dev}"
export USE_INTERNAL_REGISTRY="false"
export PR_NUMBER="${PULL_NUMBER:-}"
${VERSIONS_YAML_CONFIG:-}
oc version
cd /work
echo '--- Executing E2E Command ---'
echo 'Command: ${E2E_COMMAND:-make test.e2e.ocp}'
echo "--- Running on CI Environment: \${CI:-} ---"
echo "--- Pull Request Number: \${PR_NUMBER:-} ---"
entrypoint ${E2E_COMMAND:-make test.e2e.ocp}
rc=\$?
echo "\$rc" > ${RC_MARKER}
touch ${DONE_MARKER}
exit "\$rc"
EOF

  echo "Copying detached runner into ${MAISTRA_SC_POD}:${RUNNER_SCRIPT}"
  oc cp "${local_runner}" "${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:${RUNNER_SCRIPT}"
  rm -f "${local_runner}"
  pod_exec chmod +x "${RUNNER_SCRIPT}"

  echo "Starting detached Sail e2e suite in ${MAISTRA_SC_POD}..."
  pod_exec sh -c "nohup '${RUNNER_SCRIPT}' > '${TEST_LOG}' 2>&1 < /dev/null & echo \"Started PID \$!\""
}

# run_tests starts the detached suite and waits for completion markers.
# Returns the suite exit code from ${RC_MARKER}.
run_tests() {
  check_cluster_operators
  start_detached_tests
  if ! wait_for_tests; then
    echo "ERROR: failed while waiting for detached Sail e2e tests" >&2
    dump_full_test_log
    return 1
  fi

  dump_full_test_log

  local rc
  rc="$(read_test_rc)"
  echo "Detached suite exit code: ${rc}"
  return "${rc}"
}

# execute_and_collect_artifacts runs the test suite and copies artifacts.
# Globals:
#   MAISTRA_NAMESPACE, MAISTRA_SC_POD, ARTIFACT_DIR
# Arguments:
#   $1: The attempt number (e.g., 1 for the first run, 2 for a retry).
# Returns:
#   The exit code of the test run.
execute_and_collect_artifacts() {
  local attempt=$1
  local test_rc=0

  echo "--- Running e2e tests (attempt ${attempt}) ---"
  set +o errexit
  run_tests
  test_rc=$?
  echo "Test run (attempt ${attempt}) completed with exit code ${test_rc}"

  # Collect debug info if pod/process was killed (likely OOM)
  if [[ "${test_rc}" -eq 137 ]]; then
    collect_oom_debug_info
  fi

  echo "Copying artifacts from test pod after attempt ${attempt}..."
  oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}" || true

  # share artifacts with next job step which is uploading results to report portal, use only xml files as there is a 1MB limit
  echo "Copying artifacts to SHARED_DIR after attempt ${attempt}..."
  cp "${ARTIFACT_DIR}/"*.xml "${SHARED_DIR}" 2>/dev/null || true

  set -o errexit

  return ${test_rc}
}

# has_junit_reports checks if any JUnit XML reports exist in the artifact directory.
# Globals:
#   ARTIFACT_DIR
# Returns:
#   0 if reports are found, 1 otherwise.
has_junit_reports() {
  find "${ARTIFACT_DIR}" -type f \( -name 'junit*.xml' -o -name 'report.xml' \) -print -quit | grep -q .
}

# --- Execution ---

# Step 1: Login to quay.io using provided credentials
if [ -f /tmp/secrets/username ] && [ -f /tmp/secrets/password ]; then
    echo "Logging into quay.io registry..."
    QUAY_USERNAME=$(cat /tmp/secrets/username)
    QUAY_PASSWORD=$(cat /tmp/secrets/password)
    docker login -u="${QUAY_USERNAME}" -p="${QUAY_PASSWORD}" quay.io
else
    echo "Quay.io credentials not found. Exit with failure."
    exit 1
fi

# Step 2: Run the tests for the first time
echo "Starting e2e test execution in pod ${MAISTRA_SC_POD}..."
execute_and_collect_artifacts 1
TEST_RC=$?

# Step 3: Retry when the detached run did not complete cleanly or produced no JUnit.
# Missing markers usually mean the builder process died; RC=0 without JUnit covers
# incomplete suite runs (historically also K8s #130885 with oc rsh).
if { [[ "${TEST_RC}" -eq 0 ]] && ! has_junit_reports; } || ! are_tests_done; then
  echo "WARNING: Detached e2e run incomplete or missing JUnit (exit ${TEST_RC}). Retrying."
  echo "Retrying test execution in ${RETRY_SLEEP_INTERVAL} seconds..."
  sleep "${RETRY_SLEEP_INTERVAL}"

  echo "Cleaning up resources before retry..."
  CI=${CI:-true} BUILD_WITH_CONTAINER=0 make test.e2e.ocp.cleanup || true
  clear_test_markers

  # Retry the test execution
  execute_and_collect_artifacts 2
  TEST_RC=$?
fi

# Step 4: Final validation of artifacts
echo "--- Final Validation ---"
echo "Artifact directory contents under ${ARTIFACT_DIR}:"
ls -laR "${ARTIFACT_DIR}" || true

if ! has_junit_reports; then
  echo "ERROR: No JUnit report was found in ${ARTIFACT_DIR} after all attempts. Marking job as failed." >&2
  # If the tests seemed to pass (exit 0), force a failure code because reports are missing.
  if [[ "${TEST_RC}" -eq 0 ]]; then
    TEST_RC=1
  fi
fi

# Step 5: Exit with the final status
if [[ "${TEST_RC}" -ne 0 ]]; then
  echo "E2E tests failed with final exit code ${TEST_RC}" >&2
  exit "${TEST_RC}"
fi

echo "E2E test execution completed successfully."
exit 0
