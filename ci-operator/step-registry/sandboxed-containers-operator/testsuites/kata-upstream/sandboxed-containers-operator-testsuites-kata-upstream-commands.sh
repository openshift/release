#!/bin/bash

set -euo pipefail
# No -x: this step echoes only non-sensitive values. Exit codes are set
# explicitly (exit 0 on skip, exit 1 on the deliberate enabled failure).

STEP_NAME="SKELETON"
ENABLE_VAL="${TEST_SKELETON_ENABLE:-false}"
JUNIT="${ARTIFACT_DIR}/junit_skeleton.xml"

echo "=========================================="
echo "OSC testsuites :: skeleton"
echo "TEST_${STEP_NAME}_ENABLE=${ENABLE_VAL}"
echo "=========================================="

if [[ "${ENABLE_VAL}" != "true" ]]; then
    echo "skeleton suite DISABLED (TEST_${STEP_NAME}_ENABLE=${ENABLE_VAL}); exiting 0."
    cat > "${JUNIT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sandboxed-containers-operator-testsuites-skeleton" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="skeleton" classname="osc.testsuites.skeleton" time="0">
    <skipped message="TEST_SKELETON_ENABLE=${ENABLE_VAL}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

echo "skeleton suite ENABLED; deliberately failing to demonstrate non-blocking best_effort."
cat > "${JUNIT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sandboxed-containers-operator-testsuites-skeleton" tests="1" failures="1" errors="0" skipped="0">
  <testcase name="skeleton" classname="osc.testsuites.skeleton" time="0">
    <failure message="Deliberate skeleton failure to demonstrate non-blocking suite">Skeleton intentionally failed with TEST_SKELETON_ENABLE=true; other suites and post steps must still run.</failure>
  </testcase>
</testsuite>
EOF
echo "------------------------------------------"
echo "RESULT: FAILED (skeleton, deliberate)"
echo "JUnit written: ${JUNIT}"
echo "------------------------------------------"
exit 1
