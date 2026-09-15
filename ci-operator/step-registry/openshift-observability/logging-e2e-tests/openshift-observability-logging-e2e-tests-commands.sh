#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the cluster proxy configuration, if present.
if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    echo "setting the proxy"
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# The test framework writes kubeconfig copies and temporary files under HOME, which
# is not writable for the random UID the step runs as.
export HOME=/tmp/home
mkdir -p "${HOME}"

TESTS_EXT=openshift-logging-e2e-tests-tests-ext

# Dump the operator state next to the test results to ease debugging of failures.
function collect_operator_state() {
    echo "Collecting operator state into ${ARTIFACT_DIR}"
    oc get csv -A -o wide > "${ARTIFACT_DIR}/csv.txt" 2>&1 || true
    for ns in openshift-logging openshift-operators-redhat; do
        oc get sub,og,installplan,deploy,ds,pod -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}-resources.txt" 2>&1 || true
    done
}
trap collect_operator_state EXIT

# Prow picks up JUnit reports named junit*.xml from ARTIFACT_DIR.
report_name="junit_$(echo "${TEST_SUITE}" | tr '/-' '__').xml"

echo "Tests selected by suite ${TEST_SUITE}:"
"${TESTS_EXT}" list tests --suite "${TEST_SUITE}" -o names

echo "Running suite ${TEST_SUITE}"
if "${TESTS_EXT}" run-suite "${TEST_SUITE}" --junit-path "${ARTIFACT_DIR}/${report_name}"; then
    echo "All tests in suite ${TEST_SUITE} passed."
else
    echo "Tests in suite ${TEST_SUITE} failed, check the logs and ${report_name} for more details."
    exit 1
fi
