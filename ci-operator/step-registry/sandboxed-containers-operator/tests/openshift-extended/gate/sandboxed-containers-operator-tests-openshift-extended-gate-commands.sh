#!/bin/bash
set -euo pipefail

if [[ "${TEST_OPENSHIFT_EXTENDED_ENABLE:-}" == "false" ]]; then
    echo "TEST_OPENSHIFT_EXTENDED_ENABLE=false; skipping openshift-extended-test."
    # Record SKIP for the report gate, matching the e2e-poc/bats convention.
    # When enabled, openshift-extended-test itself writes PASS/FAIL here via
    # its TEST_RESULT_MARKER.
    mkdir -p "${SHARED_DIR}/osc-test-status"
    echo "SKIP" > "${SHARED_DIR}/osc-test-status/openshift-extended"
    mkdir -p "${ARTIFACT_DIR}"
    cat > "${ARTIFACT_DIR}/junit_openshift_extended_skipped.xml" <<EOF
<testsuite name="openshift-extended-test" tests="1" skipped="1">
  <testcase name="openshift-extended-test">
    <skipped message="TEST_OPENSHIFT_EXTENDED_ENABLE=false"/>
  </testcase>
</testsuite>
EOF
    exit 1
fi

echo "TEST_OPENSHIFT_EXTENDED_ENABLE is not false; proceeding with openshift-extended-test."
