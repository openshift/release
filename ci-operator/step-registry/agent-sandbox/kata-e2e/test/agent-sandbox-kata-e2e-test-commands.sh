#!/usr/bin/env bash
#
# Run agent-sandbox runtime-class e2e tests.
#
# Expects:
#   - KUBECONFIG in SHARED_DIR (set by cluster provisioning)
#   - agent-sandbox operator deployed
#   - kata RuntimeClass available on worker nodes
#   - Go toolchain available (from: src)

set -euo pipefail

export SHARED_DIR=${SHARED_DIR:-/tmp}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
export SANDBOX_RUNTIME_CLASS=${SANDBOX_RUNTIME_CLASS:-kata}
export SANDBOX_REPORT_DIR=${ARTIFACT_DIR:-/tmp/artifacts}

SANDBOX_TEST_TIMEOUT=${SANDBOX_TEST_TIMEOUT:-30m}
SANDBOX_TEST_PATTERN=${SANDBOX_TEST_PATTERN:-"TestRuntimeClassLifecycle|TestRuntimeClassStartupComparison"}

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo ">>> Runtime class: ${SANDBOX_RUNTIME_CLASS}"
echo ">>> Test pattern: ${SANDBOX_TEST_PATTERN}"
echo ">>> Test timeout: ${SANDBOX_TEST_TIMEOUT}"

function exit_handler() {
  local exitcode=$?
  set +e
  if [[ ${exitcode} -ne 0 ]]; then
    echo ">>> Test failure diagnostics"
    echo ">>> Pods across all namespaces:"
    oc get pods -A --no-headers 2>/dev/null | head -60 || true
    echo ">>> Sandboxes:"
    oc get sandboxes -A 2>/dev/null || true
    echo ">>> SandboxClaims:"
    oc get sandboxclaims -A 2>/dev/null || true
    echo ">>> SandboxWarmPools:"
    oc get sandboxwarmpools -A 2>/dev/null || true
    echo ">>> Controller logs (last 100 lines):"
    oc logs deployment/agent-sandbox-controller -n agent-sandbox-system --tail=100 2>/dev/null || true
  fi
}
trap 'exit_handler' EXIT

echo ">>> Installing gotestsum"
go install gotest.tools/gotestsum@latest

echo ">>> Running tests"
gotestsum \
  --junitfile="${ARTIFACT_DIR}/junit_kata-e2e.xml" \
  --jsonfile="${ARTIFACT_DIR}/kata-e2e.json" \
  -- \
  ./test/e2e/extensions/... \
  -run "${SANDBOX_TEST_PATTERN}" \
  -v -timeout "${SANDBOX_TEST_TIMEOUT}" -count=1
