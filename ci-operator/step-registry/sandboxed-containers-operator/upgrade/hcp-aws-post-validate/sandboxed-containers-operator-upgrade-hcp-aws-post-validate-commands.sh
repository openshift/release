#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. Exit code mirrors the go test runner.

# Enable-gate: skip-by-default so the suite stays non-blocking in the post chain.
ENABLE="${TESTS_OSC_ENABLE:-false}"

echo "=========================================="
echo "OSC testsuites :: osc post-upgrade (golang e2e)"
echo "TESTS_OSC_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    echo "osc suite disabled (TESTS_OSC_ENABLE=${ENABLE}); exiting 0."
    cat > "${ARTIFACT_DIR}/junit_osc_post_upgrade_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="osc-post-upgrade" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="osc-post-upgrade" classname="osc.testsuites.osc" time="0">
    <skipped message="TESTS_OSC_ENABLE=${ENABLE}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Gate --------------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/testsuites_gate" ]]; then
    echo "gate does not exist; skipping osc post-upgrade suite."
    cat > "${ARTIFACT_DIR}/junit_osc_post_upgrade_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="osc-post-upgrade" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="osc-post-upgrade" classname="osc.testsuites.osc" time="0">
    <skipped message="gate does not exist"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Configuration -----------------------------------------------------------
OPERATOR_REPO="https://github.com/openshift/sandboxed-containers-operator"
OPERATOR_REF="devel"

FOCUS="${TESTS_OSC_FOCUS:-}"
TIMEOUT="${TESTS_OSC_TIMEOUT:-120m}"

# --- Provide the tools the tests need ----------------------------------------
BINDIR="/tmp/bin"
mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"
command -v kubectl >/dev/null 2>&1 || ln -sf "$(command -v oc)" "${BINDIR}/kubectl"

for tool in go oc kubectl git; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: required tool '${tool}' not found on PATH"; exit 1; }
done

export HOME="/tmp"
export GOCACHE="/tmp/gocache"
export GOMODCACHE="/tmp/gomod"
export GOFLAGS="-mod=mod"

# --- Fetch the operator repo -------------------------------------------------
OPERATOR_DIR="$(mktemp -d /tmp/osc-XXXXXX)"
echo "Cloning ${OPERATOR_REPO} (${OPERATOR_REF})"
git clone --depth 1 -b "${OPERATOR_REF}" "${OPERATOR_REPO}" "${OPERATOR_DIR}"
cd "${OPERATOR_DIR}/test/e2e"

# --- Run the golang (Ginkgo v2) e2e tests ------------------------------------
JUNIT="$(mktemp -d /tmp/osc-results-XXXXXX)/junit_osc_post_upgrade.xml"

test_args=(-v -timeout "${TIMEOUT}" -ginkgo.junit-report="${JUNIT}" -ginkgo.no-color -ginkgo.silence-skips)
[[ -n "${FOCUS}" ]] && test_args+=(-ginkgo.focus="${FOCUS}")

echo "Running go test (post-upgrade) with timeout=${TIMEOUT}${FOCUS:+ focus=${FOCUS}}"
rc=0
go test "${test_args[@]}" ./... || rc=$?

# --- Publish JUnit -----------------------------------------------------------
shopt -s nullglob
found=0
if [[ -f "${JUNIT}" ]]; then
    found=1
    cp "${JUNIT}" "${ARTIFACT_DIR}/junit_osc_post_upgrade.xml"
fi
if [[ "${found}" -eq 0 ]]; then
    echo "ERROR: no JUnit produced at ${JUNIT}; failing the suite"
    [[ "${rc}" -eq 0 ]] && rc=1
fi

echo "osc post-upgrade go test exited ${rc}"
exit "${rc}"
