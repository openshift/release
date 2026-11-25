#!/bin/bash

# ==============================================================================
# Operator Scorecard Test Script
#
# This script runs Operator SDK scorecard tests for the Sail Operator
# to validate operator best practices and functionality.
#
# It performs the following steps:
# 1. Executes scorecard tests inside a dedicated test pod running in the
#    OpenShift cluster environment.
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

echo "Starting scorecard test execution in pod ${MAISTRA_SC_POD}..."

# Execute the scorecard tests inside the test pod
oc rsh -n "${MAISTRA_NAMESPACE}" "${MAISTRA_SC_POD}" \
  entrypoint \
  sh -c \
  "export KUBECONFIG=/work/ci-kubeconfig && \
  cd /work && \
  export BUILD_WITH_CONTAINER=\"0\" && \
  ${SCORECARD_COMMAND:-make test.scorecard}"

echo "Copying artifacts from test pod..."
# Copy artifacts from the test pod
oc cp "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":"${ARTIFACT_DIR}"/. "${ARTIFACT_DIR}"

echo "Scorecard test execution completed"