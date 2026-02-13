#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__CLUSTER_NAME="${FA__SCALE__CLUSTER_NAME:-ibm-spectrum-scale}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
junitResultsFile="${ARTIFACT_DIR}/junit_verify_cluster_tests.xml"
testStartTime=$(date +%s)
testsTotal=0
testsFailed=0
testsPassed=0
testCases=""

# Function to add test result to JUnit XML
AddTestResult() {
  local testName="$1"
  local testStatus="$2"  # "passed" or "failed"
  local testDuration="$3"
  local testMessage="${4:-}"
  local testClassName="${5:-VerifyClusterTests}"
  
  testsTotal=$((testsTotal + 1))
  
  if [[ "$testStatus" == "passed" ]]; then
    testsPassed=$((testsPassed + 1))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    testsFailed=$((testsFailed + 1))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi
}

# Function to generate JUnit XML report
GenerateJunitXml() {
  local totalDuration=$(($(date +%s) - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Verify Cluster Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : '📊 Test Results Summary:'
  : "  Total Tests: ${testsTotal}"
  : "  Passed: ${testsPassed}"
  : "  Failed: ${testsFailed}"
  : "  Duration: ${totalDuration}s"
  : "  Results File: ${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename ${junitResultsFile})"
    : '  ✅ Results copied to SHARED_DIR'
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: '🔍 Verifying IBM Storage Scale Cluster...'

# Test 1: Verify cluster exists
: '🧪 Test 1: Verify cluster exists...'
testStart=$(date +%s)
testStatus="failed"
testMessage=""

if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  : "  ✅ Cluster ${FA__SCALE__CLUSTER_NAME} exists"
  testStatus="passed"
else
  : "  ❌ Cluster ${FA__SCALE__CLUSTER_NAME} not found"
  testMessage="Cluster ${FA__SCALE__CLUSTER_NAME} not found in namespace ${FA__SCALE__NAMESPACE}"
fi

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_cluster_exists" "$testStatus" "$testDuration" "$testMessage"

# Test 2: Check cluster conditions
: '🧪 Test 2: Check cluster conditions...'
testStart=$(date +%s)
testStatus="failed"
testMessage=""

: '  Cluster conditions:'
oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" \
  -o jsonpath='{range .status.conditions[*]}    {.type}: {.status} - {.message}{"\n"}{end}'

# Check if cluster has Success condition with status True
successStatus=$(oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Success")].status}')

if [[ "${successStatus}" == "True" ]]; then
  : '  ✅ Cluster condition Success=True'
  testStatus="passed"
else
  : "  ⚠️  Cluster condition Success=${successStatus}"
  testMessage="Cluster Success condition is ${successStatus}, expected True"
fi

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_cluster_success_condition" "$testStatus" "$testDuration" "$testMessage"

# Test 3: Check pods are running
: '🧪 Test 3: Check IBM Storage Scale pods...'
testStart=$(date +%s)
testStatus="failed"
testMessage=""

: '  IBM Storage Scale pods:'
oc get pods -n "${FA__SCALE__NAMESPACE}"

# Count running pods
runningPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" --field-selector=status.phase=Running --no-headers | wc -l)
totalPods=$(oc get pods -n "${FA__SCALE__NAMESPACE}" --no-headers | wc -l)

if [[ $runningPods -gt 0 ]] && [[ $runningPods -eq $totalPods ]]; then
  : "  ✅ All ${totalPods} pods are running"
  testStatus="passed"
elif [[ $runningPods -gt 0 ]]; then
  : "  ⚠️  ${runningPods} of ${totalPods} pods are running"
  testMessage="${runningPods} of ${totalPods} pods are running"
else
  : '  ❌ No running pods found'
  testMessage="No running pods found in namespace ${FA__SCALE__NAMESPACE}"
fi

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_cluster_pods_running" "$testStatus" "$testDuration" "$testMessage"

