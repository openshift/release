#!/bin/bash
set -euo pipefail

if [[ "${TEST_UPSTREAM_KATA_BATS_ENABLE:-}" == "false" ]]; then
    echo "TEST_UPSTREAM_KATA_BATS_ENABLE=false; skipping."
    exit 0
fi

# Smoke and full BATS file lists (embedded; REVISIT *-tests.yaml mechanics later)
SMOKE_FILES="tests/integration/kubernetes/k8s-smoke.bats"
SMOKE_TIMEOUT="30m"

FULL_FILES="tests/integration/kubernetes/k8s-sandbox.bats tests/integration/kubernetes/k8s-env.bats"
FULL_TIMEOUT="60m"

echo "Cloning ${TEST_UPSTREAM_KATA_BATS_REPO} branch ${TEST_UPSTREAM_KATA_BATS_BRANCH}..."
WORKDIR=$(mktemp -d)
git clone --depth 1 --branch "${TEST_UPSTREAM_KATA_BATS_BRANCH}" "${TEST_UPSTREAM_KATA_BATS_REPO}" "${WORKDIR}"
cd "${WORKDIR}"

# Install bats if not already available
if ! command -v bats &>/dev/null; then
    echo "Installing bats..."
    if [[ -d "tests/bats" ]]; then
        cd tests/bats
        ./install.sh /usr/local
        cd "${WORKDIR}"
    else
        git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
        /tmp/bats-core/install.sh /usr/local
    fi
fi

echo "bats version: $(bats --version)"

mkdir -p "${ARTIFACT_DIR}"

run_bats() {
    local label="$1"
    local timeout="$2"
    shift 2
    local files=("$@")
    local junit_file="${ARTIFACT_DIR}/junit_${label}.xml"

    echo "Running ${label} BATS tests (timeout=${timeout})..."
    echo "  files: ${files[*]}"
    local rc=0
    timeout "${timeout}" bats \
        --formatter junit \
        "${files[@]}" \
        > "${junit_file}" 2>&1 \
        || rc=$?

    echo "${label} BATS tests finished with exit code ${rc}."
    return "${rc}"
}

# shellcheck disable=SC2086
smoke_rc=0
run_bats "smoke" "${SMOKE_TIMEOUT}" ${SMOKE_FILES} || smoke_rc=$?

if [[ "${smoke_rc}" -ne 0 ]]; then
    echo "Smoke tests failed (rc=${smoke_rc}); skipping full tests."
    cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
    exit "${smoke_rc}"
fi

if [[ "${TEST_UPSTREAM_KATA_BATS_FULL_ENABLE:-}" == "true" ]]; then
    # shellcheck disable=SC2086
    full_rc=0
    run_bats "full" "${FULL_TIMEOUT}" ${FULL_FILES} || full_rc=$?

    # Merge smoke + full JUnit into a single file
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

    exit "${full_rc}"
fi

# Smoke only
cp "${ARTIFACT_DIR}/junit_smoke.xml" "${ARTIFACT_DIR}/junit.xml" 2>/dev/null || true
