#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
junitResultsFile="${ARTIFACT_DIR}/junit_check_crds_tests.xml"
testStartTime=$SECONDS
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
  local testClassName="${5:-CheckCRDsTests}"
  
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
  local totalDuration=$((SECONDS - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Check CRDs Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
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

: '🔍 Waiting for IBM Storage Scale CRDs...'

# Test 1: Wait for CRDs to be established
testStart=$SECONDS
testStatus="failed"
testMessage=""

# The FusionAccess operator installs the IBM Storage Scale operator which creates these CRDs
if oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s; then
  : '✅ IBM Storage Scale CRDs are ready'
  testStatus="passed"
else
  : '❌ CRDs not established within timeout'
  testMessage="CRDs not established within 600s timeout"
fi

testDuration=$((SECONDS - testStart))
AddTestResult "test_storage_scale_crds_established" "$testStatus" "$testDuration" "$testMessage"

