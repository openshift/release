#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Retry sleep interval in seconds
readonly RETRY_SLEEP_INTERVAL=30

echo "Starting e2e test execution in pod ${MAISTRA_SC_POD}..."

# Execute the e2e tests inside the test pod
TEST_RC=0

# Function to run the test command
run_tests() {
  oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
    sh -c "
    export KUBECONFIG=/work/ci-kubeconfig && \
    oc version && \
    export DOCKER_INSECURE_REGISTRIES=\"default-route-openshift-image-registry.\$(oc get routes -A -o jsonpath='{.items[0].spec.host}' | awk -F. '{print substr(\$0, index(\$0,\$2))}')\" && \
    export BUILD_WITH_CONTAINER=\"0\" && \
    ${VERSIONS_YAML_CONFIG:-} \
    cd /work && \
    entrypoint \
    ${E2E_COMMAND:-make test.e2e.ocp}"
}

# Run tests but do not abort here on non-zero to ensure artifact collection
set +e
echo "Running e2e tests (attempt 1)..."
run_tests
TEST_RC=$?
set -e

echo "Initial test run completed with exit code ${TEST_RC}"

# Copy artifacts from the first test run.
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

# Check if we got exit code 0 but no JUnit reports (indicates premature exit bug)
if [[ "${TEST_RC}" -eq 0 ]] && ! find "${ARTIFACT_DIR}" -type f \( -name 'junit*.xml' -o -name 'report.xml' \) -print -quit | grep -q .; then
  echo "WARNING: oc rsh exited with 0 but no JUnit report found - likely hit Kubernetes bug #130885"
  echo "Retrying test execution once in ${RETRY_SLEEP_INTERVAL} seconds..."
  sleep "${RETRY_SLEEP_INTERVAL}"

  # Retry the test execution
  set +e
  echo "Running e2e tests (attempt 2)..."
  run_tests
  TEST_RC=$?
  set -e
  echo "Retry test run completed with exit code ${TEST_RC}"

  echo "Copying artifacts from test pod after retry..."
  oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"
fi

# Print out the copied artifact structure for debugging
echo "Artifact directory contents under ${ARTIFACT_DIR}:"
ls -laR "${ARTIFACT_DIR}"

# Validate that a JUnit report was produced
if ! find "${ARTIFACT_DIR}" -type f \( -name 'junit*.xml' -o -name 'report.xml' \) -print -quit | grep -q .; then
  echo "ERROR: No JUnit report found in ${ARTIFACT_DIR}. Marking job as failed." >&2
  if [[ "${TEST_RC}" -eq 0 ]]; then
    TEST_RC=1
  fi
fi

# Exit with the test status after artifact collection/validation
if [[ "${TEST_RC}" -ne 0 ]]; then
  echo "E2E tests failed with exit code ${TEST_RC}" >&2
  exit "${TEST_RC}"
fi

echo "E2E test execution completed"
