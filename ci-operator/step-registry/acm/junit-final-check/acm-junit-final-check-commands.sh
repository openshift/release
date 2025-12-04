#!/bin/bash
set -o nounset
set -o pipefail

################################################################################
# Final JUnit Check
################################################################################
# This step runs at the end of post phase to check all JUnit XML files.
# If any test failures are found, it exits with code 1 to mark the job as failed.
# This allows all tests to run (by using FIREWATCH_FAIL_WITH_TEST_FAILURES=false)
# while still correctly reporting the final job status.
################################################################################

echo "========================================="
echo "Final JUnit Status Check"
echo "========================================="

JUNIT_DIR="${ARTIFACT_DIR}"
TOTAL_FAILURES=0
TOTAL_TESTS=0

echo "Checking JUnit XML files in: $JUNIT_DIR"

# Find all JUnit XML files
JUNIT_FILES=$(find "$JUNIT_DIR" -name "junit*.xml" 2>/dev/null || true)

if [ -z "$JUNIT_FILES" ]; then
    echo "WARNING: No JUnit XML files found"
    exit 0
fi

# Parse each JUnit XML file
for junit_file in $JUNIT_FILES; do
    echo "Checking: $junit_file"

    # Extract failures count using grep and basic parsing
    # Format: <testsuite ... failures="N" ...>
    if grep -q '<testsuite' "$junit_file"; then
        FAILURES=$(grep '<testsuite' "$junit_file" | head -1 | sed -n 's/.*failures="\([0-9]*\)".*/\1/p')
        TESTS=$(grep '<testsuite' "$junit_file" | head -1 | sed -n 's/.*tests="\([0-9]*\)".*/\1/p')

        if [ -n "$FAILURES" ] && [ -n "$TESTS" ]; then
            echo "  Tests: $TESTS, Failures: $FAILURES"
            TOTAL_FAILURES=$((TOTAL_FAILURES + FAILURES))
            TOTAL_TESTS=$((TOTAL_TESTS + TESTS))
        fi
    fi
done

echo ""
echo "========================================="
echo "Final Summary"
echo "========================================="
echo "Total Tests: $TOTAL_TESTS"
echo "Total Failures: $TOTAL_FAILURES"
echo ""

if [ $TOTAL_FAILURES -gt 0 ]; then
    echo "❌ RESULT: Tests failed ($TOTAL_FAILURES failures)"
    echo "Job will be marked as FAILED"
    exit 1
else
    echo "✅ RESULT: All tests passed"
    echo "Job will be marked as SUCCESS"
    exit 0
fi
