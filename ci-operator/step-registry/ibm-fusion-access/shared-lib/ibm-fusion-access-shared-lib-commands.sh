#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# ============================================================================
# IBM Fusion Access Shared Library Generator
# ============================================================================
# This script generates a shared library of bash functions for JUnit XML
# test result reporting, used across all IBM Fusion Access test steps.
#
# Purpose:
#   - Centralize JUnit XML reporting functions
#   - Ensure consistent test reporting across all IBM Fusion Access tests
#   - Reduce code duplication and improve maintainability
#   - Follow OCP CI best practices for test result reporting
#
# Output:
#   - ${SHARED_DIR}/common-fusion-access-bash-functions.sh
#
# References:
#   - OCP CI JUnit XML Test Results Patterns
#   - JUnit XML Schema: https://www.ibm.com/docs/en/developer-for-zos/9.1.1?topic=formats-junit-xml-format
# ============================================================================

echo "************ IBM Fusion Access Generating Shared Functions ************"

FUNCTIONS_PATH="${SHARED_DIR}/common-fusion-access-bash-functions.sh"

cat <<'EO-SHARED-FUNCTION' > "${FUNCTIONS_PATH}"
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
#   3. Set trap for generate_junit_xml
#   4. Use add_test_result for each test case
#
# References:
#   - OCP CI JUnit XML Test Results Patterns
#   - JUnit XML Schema Standard
########################################################################

# ----------------------------------------------------------------------
# add_test_result
# ----------------------------------------------------------------------
# Adds a test case result to the JUnit XML output.
#
# This function accumulates test results in the TEST_CASES variable,
# which is later used by generate_junit_xml() to create the final
# JUnit XML report.
#
# Parameters:
#   $1 - test_name: Name of the test case (use snake_case)
#                   Example: "test_operator_installation"
#   $2 - test_status: Test result, must be "passed" or "failed"
#   $3 - test_duration: Duration in seconds (integer)
#                       Example: $(($(date +%s) - TEST_START))
#   $4 - test_message: Error message for failed tests (optional)
#                      Provide detailed failure reason for debugging
#   $5 - test_classname: Test class name (optional, defaults to "FusionAccessTests")
#                        Use PascalCase, e.g. "FusionAccessOperatorTests"
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
#   add_test_result "test_operation" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE"
# ----------------------------------------------------------------------

add_test_result() {
  local test_name="$1"
  local test_status="$2"  # "passed" or "failed"
  local test_duration="$3"
  local test_message="${4:-}"
  local test_classname="${5:-FusionAccessTests}"
  
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  
  if [[ "$test_status" == "passed" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\"/>"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\">
      <failure message=\"Test failed\">${test_message}</failure>
    </testcase>"
  fi
}

# ----------------------------------------------------------------------
# generate_junit_xml
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
#   trap generate_junit_xml EXIT
# ----------------------------------------------------------------------

generate_junit_xml() {
  local total_duration=$(($(date +%s) - TEST_START_TIME))
  
  # Ensure parent directory exists for JUnit results file
  mkdir -p "$(dirname "${JUNIT_RESULTS_FILE}")"
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="${JUNIT_SUITE_NAME:-IBM Fusion Access Tests}" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
${TEST_CASES}
  </testsuite>
</testsuites>
EOF
  
  echo ""
  echo "📊 Test Results Summary:"
  echo "  Total Tests: ${TESTS_TOTAL}"
  echo "  Passed: ${TESTS_PASSED}"
  echo "  Failed: ${TESTS_FAILED}"
  echo "  Duration: ${total_duration}s"
  echo "  Results File: ${JUNIT_RESULTS_FILE}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/$(basename ${JUNIT_RESULTS_FILE})"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
  
  # Exit with failure if any tests failed (optional behavior)
  if [[ ${TESTS_FAILED} -gt 0 ]] && [[ "${JUNIT_EXIT_ON_FAILURE:-true}" == "true" ]]; then
    echo ""
    echo "❌ Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
  fi
}

# ----------------------------------------------------------------------

EO-SHARED-FUNCTION

cat "${FUNCTIONS_PATH}"

echo ""
echo "✅ Generated shared functions at '${SHARED_DIR}/$(basename ${FUNCTIONS_PATH})'"
echo ""
ls -l "${FUNCTIONS_PATH}"
echo ""

