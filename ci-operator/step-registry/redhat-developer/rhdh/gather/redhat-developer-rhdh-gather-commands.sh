#!/bin/bash

# RHDH-specific gather step that skips heavy artifact collection on success.
# The TESTS_PASSED marker is written by the RHDH test scripts (cleanup.sh)
# when OVERALL_RESULT=0.

set +o errexit

if [[ -f "${SHARED_DIR}/TESTS_PASSED" ]]; then
  echo "TESTS_PASSED marker found — all tests passed."
  echo "Skipping must-gather and gather-extra to save ~8 minutes."
  echo "Test artifacts (JUnit XML, Playwright reports, screenshots) were already saved by the test step."
  exit 0
fi

echo "Tests failed or marker not found — collecting debugging artifacts..."

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

mkdir -p "${ARTIFACT_DIR}/must-gather" "${ARTIFACT_DIR}/gather-extra"

# --- must-gather ---
echo "Running oc adm must-gather..."
timeout 35m oc --insecure-skip-tls-verify adm must-gather \
  --dest-dir="${ARTIFACT_DIR}/must-gather" > "${ARTIFACT_DIR}/must-gather.log" 2>&1 || true

# --- gather-extra (essential subset) ---
echo "Gathering extra cluster state for debugging..."

oc --insecure-skip-tls-verify --request-timeout=5s get clusterversion -o yaml \
  > "${ARTIFACT_DIR}/gather-extra/clusterversion.yaml" 2>&1 || true
oc --insecure-skip-tls-verify --request-timeout=5s get clusteroperators -o yaml \
  > "${ARTIFACT_DIR}/gather-extra/clusteroperators.yaml" 2>&1 || true
oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o wide \
  > "${ARTIFACT_DIR}/gather-extra/nodes.txt" 2>&1 || true
oc --insecure-skip-tls-verify --request-timeout=5s get pods --all-namespaces -o wide \
  > "${ARTIFACT_DIR}/gather-extra/pods-all-namespaces.txt" 2>&1 || true
oc --insecure-skip-tls-verify --request-timeout=5s get events --all-namespaces --sort-by='.lastTimestamp' \
  > "${ARTIFACT_DIR}/gather-extra/events.txt" 2>&1 || true

# Collect RHDH-specific namespace logs
ns_file="${SHARED_DIR}/STATUS_DEPLOYMENT_NAMESPACE.txt"
if [[ -f "$ns_file" ]]; then
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    echo "Gathering logs for RHDH namespace: ${ns}"
    mkdir -p "${ARTIFACT_DIR}/gather-extra/${ns}"
    oc --insecure-skip-tls-verify --request-timeout=10s get pods -n "${ns}" -o wide \
      > "${ARTIFACT_DIR}/gather-extra/${ns}/pods.txt" 2>&1 || true
    oc --insecure-skip-tls-verify --request-timeout=10s get events -n "${ns}" --sort-by='.lastTimestamp' \
      > "${ARTIFACT_DIR}/gather-extra/${ns}/events.txt" 2>&1 || true
    oc --insecure-skip-tls-verify --request-timeout=10s describe pods -n "${ns}" \
      > "${ARTIFACT_DIR}/gather-extra/${ns}/describe-pods.txt" 2>&1 || true
    # Collect logs from all pods in the namespace
    for pod in $(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
      oc --insecure-skip-tls-verify logs "${pod}" -n "${ns}" --all-containers=true \
        > "${ARTIFACT_DIR}/gather-extra/${ns}/${pod}.log" 2>&1 || true
    done
  done < "$ns_file"
fi

echo "RHDH gather complete."
