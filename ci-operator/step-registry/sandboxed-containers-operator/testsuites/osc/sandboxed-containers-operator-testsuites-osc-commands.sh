#!/bin/bash

set -euo pipefail
# No -x: this step only echoes non-sensitive values. It does not print the
# kubeconfig or any credentials. Exit code mirrors the go test runner.

# Enable-gate: skip-by-default so the suite stays non-blocking in the post chain.
ENABLE="${TESTS_OSC_ENABLE:-false}"

echo "=========================================="
echo "OSC testsuites :: osc (golang e2e)"
echo "TESTS_OSC_ENABLE=${ENABLE}"
echo "=========================================="

if [[ "${ENABLE}" != "true" ]]; then
    echo "osc suite disabled (TESTS_OSC_ENABLE=${ENABLE}); exiting 0."
    cat > "${ARTIFACT_DIR}/junit_osc_skip.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="osc" tests="1" failures="0" errors="0" skipped="1">
  <testcase name="osc" classname="osc.testsuites.osc" time="0">
    <skipped message="TESTS_OSC_ENABLE=${ENABLE}"/>
  </testcase>
</testsuite>
EOF
    exit 0
fi

# --- Configuration -----------------------------------------------------------
# The golang e2e tests live in the operator repo. We always run them from the
# development branch.
OPERATOR_REPO="https://github.com/openshift/sandboxed-containers-operator"
OPERATOR_REF="devel"

# User-facing parameters (see the ref for defaults/documentation). They follow
# the TESTS_<SUITE_NAME>_<PARAMETER> convention shared by all OSC test suites:
#   TESTS_OSC_FOCUS   -> go test -ginkgo.focus
#   TESTS_OSC_TIMEOUT -> go test -timeout
FOCUS="${TESTS_OSC_FOCUS:-}"
TIMEOUT="${TESTS_OSC_TIMEOUT:-120m}"

# --- Provide the tools the tests need ----------------------------------------
# go and git come from the src image; oc is injected via the ref's `cli` field.
# oc is kubectl-compatible; expose it as kubectl since some helpers call kubectl.
BINDIR="/tmp/bin"
mkdir -p "${BINDIR}"
export PATH="${BINDIR}:${PATH}"
command -v kubectl >/dev/null 2>&1 || ln -sf "$(command -v oc)" "${BINDIR}/kubectl"

for tool in go oc kubectl git; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "ERROR: required tool '${tool}' not found on PATH"; exit 1; }
done

# The restricted SCC runs the step container as an arbitrary non-root UID, so
# $HOME may be read-only. Point Go's caches and module cache at writable dirs.
# test/e2e is not vendored, so allow module download (-mod=mod) using the
# image's default GOPROXY.
export HOME="/tmp"
export GOCACHE="/tmp/gocache"
export GOMODCACHE="/tmp/gomod"
export GOFLAGS="-mod=mod"

# --- Fetch the operator repo (hosts the golang e2e tests) --------------------
OPERATOR_DIR="$(mktemp -d /tmp/osc-XXXXXX)"
echo "Cloning ${OPERATOR_REPO} (${OPERATOR_REF})"
git clone --depth 1 -b "${OPERATOR_REF}" "${OPERATOR_REPO}" "${OPERATOR_DIR}"
cd "${OPERATOR_DIR}/test/e2e"

# --- Run the golang (Ginkgo v2) e2e tests ------------------------------------
# The suite reads its configuration from the osc-config configmap that the
# env-cm step already created in the cluster. Ginkgo v2 writes JUnit via
# -ginkgo.junit-report.
JUNIT="$(mktemp -d /tmp/osc-results-XXXXXX)/junit_osc.xml"

test_args=(-v -timeout "${TIMEOUT}" -ginkgo.junit-report="${JUNIT}")
[[ -n "${FOCUS}" ]] && test_args+=(-ginkgo.focus="${FOCUS}")

echo "Running go test with timeout=${TIMEOUT}${FOCUS:+ focus=${FOCUS}}"
rc=0
go test "${test_args[@]}" ./... || rc=$?

# --- Publish JUnit so prow indexes the results -------------------------------
shopt -s nullglob
found=0
if [[ -f "${JUNIT}" ]]; then
    found=1
    cp "${JUNIT}" "${ARTIFACT_DIR}/junit_osc.xml"
fi
if [[ "${found}" -eq 0 ]]; then
    # An enabled suite that yields no results is a failure: surface it even when
    # go test exited 0, so the step never "passes" silently.
    echo "ERROR: no JUnit produced at ${JUNIT}; failing the suite"
    [[ "${rc}" -eq 0 ]] && rc=1
fi

echo "osc go test exited ${rc}"
exit "${rc}"
