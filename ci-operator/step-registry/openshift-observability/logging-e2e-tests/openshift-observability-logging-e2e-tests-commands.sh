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

# ci-operator sets NAMESPACE to the build farm namespace for this job, not the
# claimed test cluster. Unset it so nothing in the test binary's process tree
# can pick it up as a default namespace for the target cluster.
unset NAMESPACE

TESTS_EXT=openshift-logging-e2e-tests-tests-ext

# Dump the operator state next to the test results to ease debugging of failures.
function collect_operator_state() {
    echo "Collecting operator state into ${ARTIFACT_DIR}"
    oc get csv -A -o wide > "${ARTIFACT_DIR}/csv.txt" 2>&1 || true
    for ns in openshift-logging openshift-operators-redhat; do
        oc get sub,og,installplan,deploy,ds,pod -n "${ns}" -o wide > "${ARTIFACT_DIR}/${ns}-resources.txt" 2>&1 || true
    done
}

# Write a flat context file and JUnit XMLs to SHARED_DIR for the qe-agent post-step.
# SHARED_DIR only supports flat files (no subdirectories); subdirs are not propagated between steps.
function notify_qe_agent() {
    local has_failures=false
    grep -rqE '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true

    local i=0
    while IFS= read -r xml; do
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "step_script_ref": "openshift-observability/logging-e2e-tests/openshift-observability-logging-e2e-tests-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "TEST_SUITE": "${TEST_SUITE:-}"
  }
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}

trap 'collect_operator_state; notify_qe_agent' EXIT

# Prow picks up JUnit reports named junit*.xml from ARTIFACT_DIR.
report_name="junit_$(echo "${TEST_SUITE}" | tr '/-' '__').xml"

echo "Tests selected by suite ${TEST_SUITE}:"
"${TESTS_EXT}" list tests --suite "${TEST_SUITE}" -o names

echo "Running suite ${TEST_SUITE}"
"${TESTS_EXT}" run-suite "${TEST_SUITE}" --junit-path "${ARTIFACT_DIR}/${report_name}" || true

# run-suite exits 0 even when individual tests fail, because every spec in this
# extension is tagged with an "informing" lifecycle (see the openshift-logging-e2e-tests
# cmd/main.go registration), so its own exit code can't be trusted to reflect test
# results. Check the JUnit report directly instead, so this step - and the PRGate
# check - actually fails when a test fails.
if [[ ! -s "${ARTIFACT_DIR}/${report_name}" ]]; then
    echo "No JUnit report was produced for suite ${TEST_SUITE}, treating as a failure."
    exit 1
elif grep -qE '<(failure|error)[ >]' "${ARTIFACT_DIR}/${report_name}"; then
    echo "Tests in suite ${TEST_SUITE} failed, check the logs and ${report_name} for more details."
    exit 1
else
    echo "All tests in suite ${TEST_SUITE} passed."
fi
