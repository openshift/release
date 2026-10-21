#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

echo "====> Waiting for Cerberus observer pod to complete and file to be ready"

# Wait for the redhat-chaos-cerberus pod to complete before collecting report
# The cerberus cleanup function creates files on EXIT, so we need to wait for completion
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
    # Look for pods with redhat-chaos-cerberus in the name across all namespaces
    cerberus_pods=$(oc get pods --all-namespaces --no-headers 2>/dev/null | grep "redhat-chaos-cerberus" || true)

    if [[ -z "$cerberus_pods" ]]; then
        echo "No Cerberus observer pods found - checking if file was already copied to observer pod"
        break
    fi

    # Check if any cerberus pods are still running
    running_pods=$(echo "$cerberus_pods" | grep -v "Completed\|Succeeded\|Failed\|Error" || true)

    if [[ -z "$running_pods" ]]; then
        echo "All Cerberus observer pods have completed"
        echo "$cerberus_pods"
        echo "Waiting additional time for cleanup handler to finish copying files..."
        sleep 15
        break
    fi

    echo "Waiting for Cerberus observer pods to complete... (${elapsed}s elapsed)"
    echo "$running_pods"
    sleep 10
    elapsed=$((elapsed + 10))
done

if [ $elapsed -ge $timeout ]; then
    echo "WARNING: Timed out waiting for Cerberus pods to complete after ${timeout}s"
    echo "Proceeding with report collection anyway..."
fi

echo ""
echo "====> Collecting Cerberus failure report"

# Find the observer pod in TEST_NAMESPACE
pods=$(oc get pods -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null || true)

if [[ -z "$pods" ]]; then
    echo "ERROR: No pods found in namespace ${TEST_NAMESPACE}"
    echo "The observer pod should have been created by the observer-start step"
    exit 1
fi

CREATED_POD_NAME=$(oc get pods -n "${TEST_NAMESPACE}" --no-headers | awk '{print $1}' | head -n 1)
echo "Found observer pod: ${CREATED_POD_NAME} in namespace ${TEST_NAMESPACE}"

# Wait for the file to exist in the observer pod (cerberus cleanup copies it there)
echo "Waiting for cerberus_history.json to be available in observer pod..."
file_timeout=60
file_elapsed=0
file_exists=false

while [ $file_elapsed -lt $file_timeout ]; do
    if oc exec -n "${TEST_NAMESPACE}" "${CREATED_POD_NAME}" -- test -f /tmp/cerberus_history.json 2>/dev/null; then
        echo "File cerberus_history.json found in observer pod"
        file_exists=true
        break
    fi
    echo "Waiting for file... (${file_elapsed}s elapsed)"
    sleep 5
    file_elapsed=$((file_elapsed + 5))
done

if [[ "$file_exists" == "false" ]]; then
    echo "ERROR: cerberus_history.json not found in observer pod after ${file_timeout}s"
    echo "Checking pod contents:"
    oc exec -n "${TEST_NAMESPACE}" "${CREATED_POD_NAME}" -- ls -la /tmp/ || true
    exit 1
fi

# Copy the cerberus_history.json file from the pod to ARTIFACT_DIR
echo "Copying /tmp/cerberus_history.json from pod to ${ARTIFACT_DIR}/${CERBERUS_REPORT_FILE}"
if ! oc cp -n "${TEST_NAMESPACE}" "${CREATED_POD_NAME}:/tmp/cerberus_history.json" "${ARTIFACT_DIR}/${CERBERUS_REPORT_FILE}"; then
    echo "ERROR: Failed to copy cerberus_history.json from pod"
    echo "Checking if file exists in pod..."
    oc exec -n "${TEST_NAMESPACE}" "${CREATED_POD_NAME}" -- ls -la /tmp/ || true
    exit 1
fi

echo "Successfully collected report file from pod"

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
  | map(select(.component | contains("netobserv")))
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
      | map(select(.component | contains("netobserv")))
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