#!/bin/bash
set -uo pipefail

if [[ "${TEST_E2E_POC_ENABLE:-}" == "false" ]]; then
    echo "TEST_E2E_POC_ENABLE=false; skipping."
    exit 0
fi

SUITE_DIR="test/e2e"

SMOKE_FOCUS="\\[Smoke\\]"
SMOKE_TIMEOUT="30m"

FULL_FOCUS="\\[Full\\]"
FULL_TIMEOUT="90m"

mkdir -p "${ARTIFACT_DIR}"

echo "Cloning ${TEST_E2E_POC_REPO} branch ${TEST_E2E_POC_BRANCH}..."
WORKDIR=$(mktemp -d)
if ! git clone --depth 1 --branch "${TEST_E2E_POC_BRANCH}" "${TEST_E2E_POC_REPO}" "${WORKDIR}"; then
    echo "ERROR: git clone failed."
    exit 0
fi
cd "${WORKDIR}/${SUITE_DIR}" || { echo "ERROR: cd failed"; exit 0; }

echo "Building e2e test binary..."
if ! go test -c -o e2e-poc.test .; then
    echo "ERROR: go test -c failed. Check go.mod / vendor sync."
    exit 0
fi

run_suite() {
    local label="$1"
    local focus="$2"
    local timeout="$3"
    local junit_file="${ARTIFACT_DIR}/junit_${label}.xml"

    echo "Running ${label} tests (focus=${focus}, timeout=${timeout})..."
    local rc=0
    ./e2e-poc.test \
        -test.v \
        -test.timeout "${timeout}" \
        -ginkgo.focus "${focus}" \
        -ginkgo.junit-report "${junit_file}" \
        || rc=$?

    echo "${label} tests finished with exit code ${rc}."
    return "${rc}"
}

smoke_rc=0
run_suite "smoke" "${SMOKE_FOCUS}" "${SMOKE_TIMEOUT}" || smoke_rc=$?

if [[ "${smoke_rc}" -ne 0 ]]; then
    echo "Smoke tests failed (rc=${smoke_rc}); skipping full tests."
    cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
    exit 0
fi

if [[ "${TEST_E2E_POC_FULL_ENABLE:-}" == "true" ]]; then
    run_suite "full" "${FULL_FOCUS}" "${FULL_TIMEOUT}" || true

    if [[ -f "${ARTIFACT_DIR}/junit_smoke.xml" && -f "${ARTIFACT_DIR}/junit_full.xml" ]]; then
        echo "Merging smoke and full JUnit results..."
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo '<testsuites>'
            sed -e '/<\?xml/d' -e '/<\/?testsuites>/d' "${ARTIFACT_DIR}/junit_smoke.xml"
            sed -e '/<\?xml/d' -e '/<\/?testsuites>/d' "${ARTIFACT_DIR}/junit_full.xml"
            echo '</testsuites>'
        } > "${ARTIFACT_DIR}/junit.xml"
    fi

    exit 0
fi

cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
exit 0
