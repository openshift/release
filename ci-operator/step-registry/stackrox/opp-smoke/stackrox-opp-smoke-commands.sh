#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# ACS OPP SMOKE Test Runner
#
# Runs the stackrox qa-tests-backend testSMOKE suite against an ACS
# instance whose credentials were written to $SHARED_DIR by the
# stackrox-opp-readiness step.
#
# Image: acs-smoke-runner (UBI9 + OpenJDK 17 + git + oc)
# ---------------------------------------------------------------------------

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

# ---------------------------------------------------------------------------
# Read credentials from SHARED_DIR (written by readiness gate)
# ---------------------------------------------------------------------------
echo "[smoke] Reading connection details from SHARED_DIR..."

CENTRAL_URL="$(cat "${SHARED_DIR}/CENTRAL_URL")"

set +x
ROX_ADMIN_PASSWORD="$(cat "${SHARED_DIR}/ROX_ADMIN_PASSWORD")"

echo "[smoke] Connection details loaded from SHARED_DIR"

# Allow pinning to a known-good ref for reproducibility
STACKROX_REF="${STACKROX_REF:-main}"
SCANNER_REF="${SCANNER_REF:-main}"

# ---------------------------------------------------------------------------
# Retry wrapper for network-dependent operations
# ---------------------------------------------------------------------------
retry_clone() {
    local max_attempts=3
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi
        echo "[smoke] Clone attempt $attempt/$max_attempts failed, retrying in 10s..."
        sleep 10
        attempt=$((attempt + 1))
    done
    echo "[smoke] ERROR: Clone failed after $max_attempts attempts"
    return 1
}

# ---------------------------------------------------------------------------
# Sparse clone of stackrox/stackrox (qa-tests-backend + proto)
# ---------------------------------------------------------------------------
echo "[smoke] Sparse-cloning stackrox/stackrox..."
cd /tmp
retry_clone git clone --depth 1 --filter=blob:none --sparse --branch "${STACKROX_REF}" \
    https://github.com/stackrox/stackrox.git stackrox
cd stackrox
git sparse-checkout set qa-tests-backend/ proto/

# ---------------------------------------------------------------------------
# Fetch scanner protos (no Go toolchain needed)
# ---------------------------------------------------------------------------
echo "[smoke] Fetching scanner protos..."
retry_clone git clone --depth 1 --filter=blob:none --sparse --branch "${SCANNER_REF}" \
    https://github.com/stackrox/scanner.git /tmp/scanner
cd /tmp/scanner
git sparse-checkout set proto/scanner
cp -r proto/scanner /tmp/stackrox/qa-tests-backend/src/main/proto/scanner
chmod -R u+w /tmp/stackrox/qa-tests-backend/src/main/proto/scanner

# ---------------------------------------------------------------------------
# Set environment for the Gradle test suite
# ---------------------------------------------------------------------------
export API_HOSTNAME="${CENTRAL_URL}"
export API_PORT="443"
export ROX_USERNAME="admin"
export ROX_ADMIN_PASSWORD
export CLUSTER="OPENSHIFT"
export CI="true"

# ---------------------------------------------------------------------------
# Run testSMOKE
# ---------------------------------------------------------------------------
echo "[smoke] Running testSMOKE..."
cd /tmp/stackrox/qa-tests-backend

TEST_EXIT=0
./gradlew testSMOKE -i --no-daemon -Dorg.gradle.jvmargs="-Xmx3g" || TEST_EXIT=$?

# ---------------------------------------------------------------------------
# Copy JUnit XML results to ARTIFACT_DIR
# ---------------------------------------------------------------------------
collect_artifacts() {
    if [[ -d build/test-results/testSMOKE ]]; then
        cp -v build/test-results/testSMOKE/*.xml "${ARTIFACT_DIR}/" 2>/dev/null || true
    fi
    if [[ -d build/reports/tests/testSMOKE ]]; then
        mkdir -p "${ARTIFACT_DIR}/smoke-report" 2>/dev/null || true
        cp -r build/reports/tests/testSMOKE/* "${ARTIFACT_DIR}/smoke-report/" 2>/dev/null || true
    fi
}
collect_artifacts || true

echo "[smoke] Test run finished with exit code: ${TEST_EXIT}"
exit "${TEST_EXIT}"
