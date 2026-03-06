#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

echo "====> Collecting Cerberus failure report"

# First try to read from SHARED_DIR (preferred method)
if [[ -f "${SHARED_DIR}/cerberus_history.json" ]]; then
    echo "Found cerberus_history.json in SHARED_DIR"
    cp "${SHARED_DIR}/cerberus_history.json" "${ARTIFACT_DIR}/${CERBERUS_REPORT_FILE}"
    echo "Successfully collected report file from SHARED_DIR"
else
    echo "cerberus_history.json not found in SHARED_DIR, trying to collect from pod..."

    # Fallback: Get the pod name from the test namespace
    pods=$(oc get pods -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null || true)

    if [[ -z "$pods" ]]; then
        echo "ERROR: No pods found in namespace ${TEST_NAMESPACE} and no file in SHARED_DIR"
        exit 1
    fi

    CREATED_POD_NAME=$(oc get pods -n "${TEST_NAMESPACE}" --no-headers | awk '{print $1}' | head -n 1)
    echo "Found pod: ${CREATED_POD_NAME} in namespace ${TEST_NAMESPACE}"

    # Copy the cerberus_history.json file from the pod to ARTIFACT_DIR
    echo "Copying /tmp/cerberus_history.json from pod to ${ARTIFACT_DIR}/${CERBERUS_REPORT_FILE}"
    if ! oc cp -n "${TEST_NAMESPACE}" "${CREATED_POD_NAME}:/tmp/cerberus_history.json" "${ARTIFACT_DIR}/${CERBERUS_REPORT_FILE}"; then
        echo "ERROR: Failed to copy cerberus_history.json from pod"
        echo "Checking if file exists in pod..."
        oc exec -n "${TEST_NAMESPACE}" "${CREATED_POD_NAME}" -- ls -la /tmp/ || true
        exit 1
    fi

    echo "Successfully collected report file from pod"
fi

echo ""
echo "====> Analyzing Cerberus failure report"

# Check if report file exists
REPORT_PATH="${ARTIFACT_DIR}/${CERBERUS_REPORT_FILE}"
if [[ ! -f "${REPORT_PATH}" ]]; then
    echo "ERROR: Cerberus report file not found at ${REPORT_PATH}"
    echo "Please ensure the file exists before running this step."
    exit 1
fi

echo "Found report file: ${REPORT_PATH}"

# Extract and analyze failures by component
echo ""
echo "====> Component Failure Summary"
echo "=============================="

# Use jq to group failures by component and count them
COMPONENT_SUMMARY=$(jq -r '
  .history.failures
  | group_by(.component)
  | map({
      component: .[0].component,
      count: length,
      pod_crashes: map(.name) | unique | length
    })
  | sort_by(-.count)
  | .[]
  | "\(.component):\n  Total failures: \(.count)\n  Unique pods: \(.pod_crashes)"
' "${REPORT_PATH}")

echo "${COMPONENT_SUMMARY}"

# Get total failure count
TOTAL_FAILURES=$(jq '.history.failures | length' "${REPORT_PATH}")
echo ""
echo "Total failures: ${TOTAL_FAILURES}"

# Check for netobserv component failures
echo ""
echo "====> Checking for NetObserv component failures"

NETOBSERV_FAILURES=$(jq -r '
  .history.failures
  | map(select(.component | startswith("netobserv")))
  | group_by(.component)
  | map({
      component: .[0].component,
      count: length
    })
' "${REPORT_PATH}")

NETOBSERV_COUNT=$(echo "${NETOBSERV_FAILURES}" | jq '. | length')

if [[ "${NETOBSERV_COUNT}" -gt 0 ]]; then
    echo "FAILURE: Found failures in NetObserv components:"
    echo "${NETOBSERV_FAILURES}" | jq -r '.[] | "  - \(.component): \(.count) failures"'

    # Create detailed failure report for netobserv components
    echo ""
    echo "====> Detailed NetObserv Failure Report"
    jq -r '
      .history.failures
      | map(select(.component | startswith("netobserv")))
      | group_by(.component)
      | .[]
      | "Component: \(.[0].component)\nFailures:\n" + (
          map("  - \(.timestamp) | \(.name) | \(.issue)") | join("\n")
        ) + "\n"
    ' "${REPORT_PATH}"

    exit 1
else
    echo "SUCCESS: No failures found in NetObserv components"
    exit 0
fi