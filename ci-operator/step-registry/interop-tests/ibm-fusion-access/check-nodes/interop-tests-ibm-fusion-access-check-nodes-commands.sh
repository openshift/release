#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# JUnit XML test results configuration
junitResultsFile="${ARTIFACT_DIR}/junit_check_nodes_tests.xml"
testStartTime=$(date +%s)
testsTotal=0
testsFailed=0
testsPassed=0
testCases=""

# Function to add test result to JUnit XML
AddTestResult() {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift  # "passed" or "failed"
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-CheckNodesTests}"; (($#)) && shift
  
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

  true
}

# Function to generate JUnit XML report
GenerateJunitXml() {
  typeset totalDuration=$(($(date +%s) - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Check Nodes Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
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

  true
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: '🔍 Checking worker nodes...'

# Test 1: Verify minimum worker node count for quorum
testStart=$(date +%s)
testStatus="failed"
testMessage=""

workerNodeCount=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $workerNodeCount -lt 3 ]]; then
  : "⚠️  WARNING: Only $workerNodeCount worker nodes (minimum 3 required for quorum)"
  testMessage="Insufficient worker nodes: found $workerNodeCount, minimum 3 required for quorum"
else
  : "✅ Found $workerNodeCount worker nodes (quorum requirements met)"
  testStatus="passed"
fi

: 'Worker nodes:'
oc get nodes -l node-role.kubernetes.io/worker

testDuration=$(($(date +%s) - testStart))
AddTestResult "test_worker_node_count_for_quorum" "$testStatus" "$testDuration" "$testMessage"

true
