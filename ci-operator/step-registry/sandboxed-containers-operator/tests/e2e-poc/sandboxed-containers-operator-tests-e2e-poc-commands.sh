#!/bin/bash
set -uo pipefail

# This step runs best_effort: true in the tests chain, so a non-zero exit here
# does not stop later steps. It records its real outcome (PASS/FAIL/SKIP) to
# ${SHARED_DIR}/osc-test-status/, which the terminal
# sandboxed-containers-operator-tests-report step reads to fail the job when any
# test step fails. Exiting non-zero on failure also marks this step red in the
# per-step view.
STATUS_DIR="${SHARED_DIR}/osc-test-status"
mkdir -p "${STATUS_DIR}"
STATUS_FILE="${STATUS_DIR}/e2e-poc"
record_status() { echo "$1" > "${STATUS_FILE}"; }

fail_junit() {
    local msg="$1"
    mkdir -p "${ARTIFACT_DIR}"
    cat > "${ARTIFACT_DIR}/junit.xml" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="e2e-poc-setup" tests="1" failures="1">
  <testcase name="setup"><failure message="${msg}"/></testcase>
</testsuite>
JEOF
}

# Record the failure and exit non-zero so the report step fails the job.
fail_step() {
    local msg="$1"
    echo "ERROR: ${msg}"
    fail_junit "${msg}"
    record_status "FAIL"
    exit 1
}

if [[ "${TEST_E2E_POC_ENABLE:-}" == "false" ]]; then
    echo "TEST_E2E_POC_ENABLE=false; skipping."
    record_status "SKIP"
    exit 0
fi

SUITE_DIR="test/e2e"

SMOKE_FOCUS="\\[Smoke\\]"
FULL_FOCUS="\\[Full\\]"
TEST_TIMEOUT="120m"

mkdir -p "${ARTIFACT_DIR}"

echo "Cloning ${TEST_E2E_POC_REPO} branch ${TEST_E2E_POC_BRANCH}..."
WORKDIR=$(mktemp -d)
if ! git clone --depth 1 --branch "${TEST_E2E_POC_BRANCH}" "${TEST_E2E_POC_REPO}" "${WORKDIR}"; then
    fail_step "git clone failed"
fi
cd "${WORKDIR}/${SUITE_DIR}" || fail_step "cd to suite dir failed"

run_suite() {
    local label="$1"
    local focus="$2"
    local junit_file="${ARTIFACT_DIR}/junit_${label}.xml"

    echo "Running ${label} tests (focus=${focus}, timeout=${TEST_TIMEOUT})..."
    local rc=0
    go test -v -timeout "${TEST_TIMEOUT}" \
        -ginkgo.focus "${focus}" \
        -ginkgo.junit-report "${junit_file}" \
        ./... \
        || rc=$?

    echo "${label} tests finished with exit code ${rc}."
    return "${rc}"
}

smoke_rc=0
run_suite "smoke" "${SMOKE_FOCUS}" || smoke_rc=$?

if [[ "${smoke_rc}" -ne 0 ]]; then
    echo "Smoke tests failed (rc=${smoke_rc}); skipping full tests."
    cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
    record_status "FAIL"
    exit 1
fi

if [[ "${TEST_E2E_POC_FULL_ENABLE:-}" == "true" ]]; then
    full_rc=0
    run_suite "full" "${FULL_FOCUS}" || full_rc=$?

    if [[ -f "${ARTIFACT_DIR}/junit_smoke.xml" && -f "${ARTIFACT_DIR}/junit_full.xml" ]]; then
        echo "Merging smoke and full JUnit results..."
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo '<testsuites>'
            sed -e '/<\?xml/d' -e '/<testsuites>/d' -e '/<\/testsuites>/d' "${ARTIFACT_DIR}/junit_smoke.xml"
            sed -e '/<\?xml/d' -e '/<testsuites>/d' -e '/<\/testsuites>/d' "${ARTIFACT_DIR}/junit_full.xml"
            echo '</testsuites>'
        } > "${ARTIFACT_DIR}/junit.xml"
    else
        cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
    fi

    if [[ "${full_rc}" -ne 0 ]]; then
        echo "Full tests failed (rc=${full_rc})."
        record_status "FAIL"
        exit 1
    fi

    record_status "PASS"
    exit 0
fi

cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
record_status "PASS"
exit 0
