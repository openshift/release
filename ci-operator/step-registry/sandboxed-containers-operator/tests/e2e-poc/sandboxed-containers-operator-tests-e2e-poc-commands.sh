#!/bin/bash
set -euo pipefail

if [[ "${TEST_E2E_POC_ENABLE:-}" == "false" ]]; then
    echo "TEST_E2E_POC_ENABLE=false; skipping."
    exit 0
fi

SUITE_DIR="test/e2e"

SMOKE_FOCUS="\\[Smoke\\]"
SMOKE_TIMEOUT="30m"

FULL_FOCUS="\\[Full\\]"
FULL_TIMEOUT="90m"

echo "Cloning ${TEST_E2E_POC_REPO} branch ${TEST_E2E_POC_BRANCH}..."
WORKDIR=$(mktemp -d)
git clone --depth 1 --branch "${TEST_E2E_POC_BRANCH}" "${TEST_E2E_POC_REPO}" "${WORKDIR}"
cd "${WORKDIR}/${SUITE_DIR}"

echo "Building e2e test binary..."
go test -c -o e2e-poc.test .

mkdir -p "${ARTIFACT_DIR}"

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
    exit "${smoke_rc}"
fi

if [[ "${TEST_E2E_POC_FULL_ENABLE:-}" == "true" ]]; then
    full_rc=0
    run_suite "full" "${FULL_FOCUS}" "${FULL_TIMEOUT}" || full_rc=$?

    # Merge smoke + full JUnit into a single file
    if [[ -f "${ARTIFACT_DIR}/junit_smoke.xml" && -f "${ARTIFACT_DIR}/junit_full.xml" ]]; then
        echo "Merging smoke and full JUnit results..."
        {
            echo '<?xml version="1.0" encoding="UTF-8"?>'
            echo '<testsuites>'
            # Extract testsuites/testsuite content from each file, stripping XML headers
            sed -e '/<\?xml/d' -e '/<\/?testsuites>/d' "${ARTIFACT_DIR}/junit_smoke.xml"
            sed -e '/<\?xml/d' -e '/<\/?testsuites>/d' "${ARTIFACT_DIR}/junit_full.xml"
            echo '</testsuites>'
        } > "${ARTIFACT_DIR}/junit.xml"
    fi

    exit "${full_rc}"
fi

# Smoke only — use smoke result as the final JUnit
cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
