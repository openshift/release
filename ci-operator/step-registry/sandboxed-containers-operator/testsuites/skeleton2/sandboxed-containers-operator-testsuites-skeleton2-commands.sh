#!/bin/bash

set -euo pipefail
# No -x: this step echoes only non-sensitive values. Exit codes are set
# explicitly (exit 0 on skip, exit 0 on the deliberate enabled success).

STEP_NAME="SKELETON2"
ENABLE_VAL="${TESTS_SKELETON2_ENABLE:-false}"
JUNIT="${ARTIFACT_DIR}/junit_skeleton2.xml"

echo "=========================================="
echo "OSC testsuites :: skeleton2"
echo "TESTS_${STEP_NAME}_ENABLE=${ENABLE_VAL}"
echo "=========================================="

if [[ "${ENABLE_VAL}" != "true" ]]; then
    echo "skeleton2 suite DISABLED (TESTS_${STEP_NAME}_ENABLE=${ENABLE_VAL}); exiting 0."
    cat > "${JUNIT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sandboxed-containers-operator-testsuites-skeleton2" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="skeleton2" classname="osc.testsuites.skeleton2" time="0">
    <skipped message="TESTS_SKELETON2_ENABLE=${ENABLE_VAL}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

echo "skeleton2 suite ENABLED; always succeeds -- demonstrates it runs even after an earlier suite fails."
cat > "${JUNIT}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sandboxed-containers-operator-testsuites-skeleton2" tests="1" failures="0" errors="0" skipped="0">
  <testcase name="skeleton2" classname="osc.testsuites.skeleton2" time="0"/>
</testsuite>
EOF
echo "------------------------------------------"
echo "RESULT: PASSED (skeleton2)"
echo "JUnit written: ${JUNIT}"
echo "------------------------------------------"
exit 0
