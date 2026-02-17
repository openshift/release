#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Generating IBM Fusion Access shared functions'

functionsPath="${SHARED_DIR}/common-fusion-access-bash-functions.sh"

cat <<'EO-SHARED-FUNCTION' > "${functionsPath}"
########################################################################
# IBM Fusion Access Shared Test Functions
########################################################################
# Common JUnit XML test result reporting functions used by multiple
# IBM Fusion Access test steps.
#
# These functions provide standardized test result reporting that
# integrates with OCP CI test platform, Prow/Spyglass visualization,
# and component readiness dashboards.
#
# Usage:
#   1. Source this file in your test script
#   2. Initialize required variables
#   3. Set trap for GenerateJunitXml
#   4. Use AddTestResult for each test case
#
# References:
#   - OCP CI JUnit XML Test Results Patterns
#   - JUnit XML Schema Standard
########################################################################

# ----------------------------------------------------------------------
# AddTestResult
# ----------------------------------------------------------------------
# Adds a test case result to the JUnit XML output.
#
# This function accumulates test results in the TEST_CASES variable,
# which is later used by GenerateJunitXml() to create the final
# JUnit XML report.
#
# Parameters:
#   $1 - testName: Name of the test case (use snake_case)
#                  Example: "test_operator_installation"
#   $2 - testStatus: Test result, must be "passed" or "failed"
#   $3 - testDuration: Duration in seconds (integer)
#                      Example: $(($(date +%s) - TEST_START))
#   $4 - testMessage: Error message for failed tests (optional)
#                     Provide detailed failure reason for debugging
#   $5 - testClassName: Test class name (optional, defaults to "FusionAccessTests")
#                       Use PascalCase, e.g. "FusionAccessOperatorTests"
#
# Global Variables Modified:
#   - TESTS_TOTAL: Incremented by 1
#   - TESTS_PASSED: Incremented by 1 if test passed
#   - TESTS_FAILED: Incremented by 1 if test failed
#   - TEST_CASES: Appended with test case XML
#
# Example:
#   TEST1_START=$(date +%s)
#   TEST1_STATUS="failed"
#   TEST1_MESSAGE=""
#   
#   if perform_test; then
#     TEST1_STATUS="passed"
#   else
#     TEST1_MESSAGE="Failed to perform test: specific reason"
#   fi
#   
#   TEST1_DURATION=$(($(date +%s) - TEST1_START))
#   AddTestResult "test_operation" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE"
# ----------------------------------------------------------------------

AddTestResult() {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift  # "passed" or "failed"
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-FusionAccessTests}"; (($#)) && shift
  
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  
  if [[ "$testStatus" == "passed" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi

  true
}

# ----------------------------------------------------------------------
# GenerateJunitXml
# ----------------------------------------------------------------------
# Generates the final JUnit XML test results report.
#
# This function should be called at the end of test execution (typically
# via a trap on EXIT) to generate the final JUnit XML report file.
#
# The function:
#   1. Calculates total test suite duration
#   2. Generates JUnit XML file with all accumulated test results
#   3. Prints test summary to console
#   4. Copies results to SHARED_DIR for data router reporter
#   5. Exits with error code if tests failed (configurable)
#
# Required Global Variables:
#   - JUNIT_RESULTS_FILE: Path to output XML file (string)
#                         Example: "${ARTIFACT_DIR}/junit_fusion_access_tests.xml"
#   - TEST_START_TIME: Start time of test suite (unix timestamp)
#                      Example: $(date +%s)
#   - TESTS_TOTAL: Total number of tests executed (integer)
#   - TESTS_FAILED: Number of failed tests (integer)
#   - TESTS_PASSED: Number of passed tests (integer)
#   - TEST_CASES: Accumulated test case XML (string)
#
# Optional Global Variables:
#   - JUNIT_SUITE_NAME: Name of the test suite (string)
#                       Default: "IBM Fusion Access Tests"
#   - JUNIT_EXIT_ON_FAILURE: Exit with error if tests failed (boolean string)
#                            Default: "true"
#                            Set to "false" to suppress exit on failure
#   - SHARED_DIR: Directory for sharing artifacts between steps (string)
#                 If set and exists, results are copied here
#
# Output:
#   - JUnit XML file at ${JUNIT_RESULTS_FILE}
#   - Copy in ${SHARED_DIR} (if available)
#   - Console test summary
#
# Exit Code:
#   - 1 if TESTS_FAILED > 0 and JUNIT_EXIT_ON_FAILURE="true" (default)
#   - 0 otherwise
#
# Example Setup:
#   ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
#   JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_fusion_access_tests.xml"
#   JUNIT_SUITE_NAME="IBM Fusion Access Operator Installation Tests"
#   TEST_START_TIME=$(date +%s)
#   TESTS_TOTAL=0
#   TESTS_FAILED=0
#   TESTS_PASSED=0
#   TEST_CASES=""
#   
#   trap GenerateJunitXml EXIT
# ----------------------------------------------------------------------

GenerateJunitXml() {
  typeset totalDuration=$(($(date +%s) - TEST_START_TIME))
  
  mkdir -p "$(dirname "${JUNIT_RESULTS_FILE}")"
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="${JUNIT_SUITE_NAME:-IBM Fusion Access Tests}" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${totalDuration}">
${TEST_CASES}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results: Total=${TESTS_TOTAL} Passed=${TESTS_PASSED} Failed=${TESTS_FAILED} Duration=${totalDuration}s Results=${JUNIT_RESULTS_FILE}"
  
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/$(basename ${JUNIT_RESULTS_FILE})"
    : 'Results copied to SHARED_DIR'
  fi
  
  if [[ ${TESTS_FAILED} -gt 0 ]] && [[ "${JUNIT_EXIT_ON_FAILURE:-true}" == "true" ]]; then
    : "Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
  fi

  true
}

# ----------------------------------------------------------------------

EO-SHARED-FUNCTION

cat "${functionsPath}"

: "Generated shared functions at '${SHARED_DIR}/$(basename ${functionsPath})'"
ls -l "${functionsPath}"

true
