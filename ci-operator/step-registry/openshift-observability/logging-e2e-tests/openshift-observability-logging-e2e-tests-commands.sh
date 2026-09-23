#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi
export HOME=/tmp/home
mkdir -p "${HOME}"
unset NAMESPACE

TESTS_EXT=openshift-logging-e2e-tests-tests-ext

# Set report_name early so the EXIT trap can safely reference it.
report_name="junit_$(echo "${TEST_SUITE}" | tr '/-' '__').xml"

function collect_operator_state() {
    echo "=== Collecting operator state for debugging ==="
    oc get clusterlogging -A -o yaml 2>/dev/null || true
    oc get lokistack -A -o yaml 2>/dev/null || true
    oc get csv -n openshift-logging 2>/dev/null || true
    oc get csv -n openshift-operators-redhat 2>/dev/null || true
    oc get pods -n openshift-logging 2>/dev/null || true
    oc get pods -n openshift-operators-redhat 2>/dev/null || true
}

function notify_qe_agent() {
    local has_failures=false
    local junit_file="${ARTIFACT_DIR}/${report_name}"

    # Detect failures in the JUnit report and copy it with the prefix the QE agent expects.
    if [[ -f "${junit_file}" ]]; then
        if grep -qE '<(failure|error)' "${junit_file}" 2>/dev/null; then
            has_failures=true
        fi
        cp "${junit_file}" "${SHARED_DIR}/qe-agent-junit-${report_name}" 2>/dev/null || true
    fi

    # Write the context file the openshift-observability-qe-agent post step reads.
    # The agent skips unless has_test_failures is true.
    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "has_test_failures": ${has_failures},
  "suite": "${TEST_SUITE}",
  "jiraProject": "${JIRA_PROJECT:-}",
  "agentSkill": "${AGENT_SKILL:-}"
}
EOF
}

trap 'collect_operator_state; notify_qe_agent' EXIT

echo "=== Listing tests in suite: ${TEST_SUITE} ==="
"${TESTS_EXT}" list tests --suite "${TEST_SUITE}" -o names

echo "=== Running suite: ${TEST_SUITE} (max-concurrency=${TEST_MAX_CONCURRENCY:-1}) ==="
"${TESTS_EXT}" run-suite "${TEST_SUITE}" \
    --max-concurrency "${TEST_MAX_CONCURRENCY:-1}" \
    --junit-path "${ARTIFACT_DIR}/${report_name}" || true
