#!/bin/bash

# ==============================================================================
# E2E Test Runner Script
#
# This script runs end-to-end tests for E2E in an OpenShift cluster.
#
# It performs the following steps:
# 1. Verifies the internal OCP image registry is running. If not, it creates
#    the default route.
# 2. Waits for all ClusterOperators to become stable. This is done to ensure
#    that the cluster is in a good state before running tests to avoid the oc rsh exit code 0 issue
# 3. Executes the e2e test suite inside a dedicated pod.
# 4. Collects test artifacts (like JUnit reports).
# 5. Implements a retry mechanism for a specific known issue where tests
#    pass but no reports are generated.
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

# --- Functions ---

# verify_internal_registry checks that the internal OpenShift image registry is
# available and running, creating the default route if it doesn't exist.
verify_internal_registry() {
  echo "Verifying internal OCP image registry..."
  oc get pods -n openshift-image-registry --no-headers | grep -v "Running\|Completed" && \
    echo "ERROR: OCP image registry is not running. Aborting. OCP image registry needs to be installed in the cluster" && exit 1

  if [ -z "$(oc get route default-route -n openshift-image-registry -o name)" ]; then
    echo "Creating default route for image registry..."
    oc patch configs.imageregistry.operator.openshift.io/cluster \
      --patch '{"spec":{"defaultRoute":true}}' --type=merge

    echo "Waiting for the route to be ready..."
    if ! timeout 3m bash -c \
      "until oc get route default-route -n openshift-image-registry &>/dev/null; do sleep 5; done"; then
      echo "ERROR: Timed out waiting for the image registry route to become available." >&2
      exit 1
    fi
    echo "Image registry route is ready."
  fi
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
    local unstable_operators_json
    unstable_operators_json=$(oc get clusteroperator -o json | jq -r '[.items[] | select(.status.conditions[] | (.type == "Available" and .status == "False") or (.type == "Progressing" and .status == "True") or (.type == "Degraded" and .status == "True")) | .metadata.name]')

    if [ $? -ne 0 ]; then
        echo "WARN: 'oc get clusteroperator' command failed. Resetting stability count and retrying."
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

# run_tests executes the main test command inside the test pod.
run_tests() {
  # Pre-flight check to ensure cluster is stable before running tests
  check_cluster_operators

  oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
    sh -c "
    export KUBECONFIG=/work/ci-kubeconfig
    export ENABLE_OVERLAY2_STORAGE_DRIVER=true
    export BUILD_WITH_CONTAINER=\"0\"
    export DOCKER_INSECURE_REGISTRIES=\"default-route-openshift-image-registry.\$(oc get routes -A -o jsonpath='{.items[0].spec.host}' | awk -F. '{print substr(\$0, index(\$0,\$2))}')\"
    ${VERSIONS_YAML_CONFIG:-}
    oc version
    cd /work
    entrypoint ${E2E_COMMAND:-make test.e2e.ocp}
    "
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

  echo "Copying artifacts from test pod after attempt ${attempt}..."
  oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

  # share artifacts with next job step which is uploading results to report portal
  echo "Copying artifacts to SHARED_DIR after attempt ${attempt}..."
  cp "${ARTIFACT_DIR}/"* "${SHARED_DIR}"

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

# Step 1: Verify if internal OCP registry is up and running and if there is a route to access to the registry
verify_internal_registry

# Step 2: Run the tests for the first time
echo "Starting e2e test execution in pod ${MAISTRA_SC_POD}..."
execute_and_collect_artifacts 1
TEST_RC=$?

# Step 3: Check for the specific premature exit bug and retry if necessary
# The bug is identified by a '0' exit code but no JUnit reports being generated.
if [[ "${TEST_RC}" -eq 0 ]] && ! has_junit_reports; then
  echo "WARNING: oc rsh exited with 0 but no JUnit report found. This may indicate a known bug (e.g., K8s #130885)."
  echo "Retrying test execution in ${RETRY_SLEEP_INTERVAL} seconds..."
  sleep "${RETRY_SLEEP_INTERVAL}"

  echo "Cleaning up resources before retry..."
  BUILD_WITH_CONTAINER=0 make test.e2e.ocp.cleanup

  # Retry the test execution
  execute_and_collect_artifacts 2
  TEST_RC=$?
fi

# Step 4: Final validation of artifacts
echo "--- Final Validation ---"
echo "Artifact directory contents under ${ARTIFACT_DIR}:"
ls -laR "${ARTIFACT_DIR}"

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
