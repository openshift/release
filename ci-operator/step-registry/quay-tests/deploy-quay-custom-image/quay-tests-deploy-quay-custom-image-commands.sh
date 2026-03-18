#!/bin/bash

set -uo pipefail
set -x

NAMESPACE="quay-enterprise"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

collect_debug_info() {
  echo "=== Collecting debug info for failed deployment ==="

  echo "--- Deployment describe ---"
  oc -n "${NAMESPACE}" describe "deployment/${QUAY_DEPLOY}" 2>&1 | tee "${ARTIFACT_DIR}/deployment-describe.txt"

  echo "--- Pod status ---"
  oc -n "${NAMESPACE}" get pods -o wide 2>&1 | tee "${ARTIFACT_DIR}/pod-status.txt"

  echo "--- Describe non-Ready quay-app pods ---"
  oc -n "${NAMESPACE}" get pods -l quay-component=quay-app -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\n"}{end}' | while read -r pod; do
    if [[ -n "${pod}" ]]; then
      echo "--- Describe pod: ${pod} ---"
      oc -n "${NAMESPACE}" describe pod "${pod}"
    fi
  done 2>&1 | tee "${ARTIFACT_DIR}/non-ready-pods-describe.txt"

  echo "--- Quay-app pod logs ---"
  oc -n "${NAMESPACE}" get pods -l quay-component=quay-app -o name | while read -r pod; do
    echo "--- Logs for ${pod} ---"
    oc -n "${NAMESPACE}" logs "${pod}" --tail=100 2>&1 || true
    echo "--- Previous logs for ${pod} ---"
    oc -n "${NAMESPACE}" logs "${pod}" --previous --tail=50 2>&1 || true
  done 2>&1 | tee "${ARTIFACT_DIR}/quay-app-pod-logs.txt"

  echo "--- Namespace events (last 10 min) ---"
  oc -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' 2>&1 | tee "${ARTIFACT_DIR}/namespace-events.txt"
}

echo "Swapping Quay image to CI-built: ${QUAY_CI_IMAGE}"

# Debug: show current state of the namespace
oc -n "${NAMESPACE}" get deployments
oc -n "${NAMESPACE}" get pods
oc -n "${NAMESPACE}" get subscription quay-operator -o yaml || true

# Scale down operator to prevent reconciliation overwriting our image change
# The operator is deployed via OLM, so we find it through the CSV
echo "Scaling down quay-operator..."
CSV=$(oc -n "${NAMESPACE}" get subscription quay-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
if [[ -n "${CSV}" ]]; then
  OPERATOR_DEPLOY=$(oc -n "${NAMESPACE}" get csv "${CSV}" -o jsonpath='{.spec.install.spec.deployments[0].name}' 2>/dev/null || true)
  if [[ -n "${OPERATOR_DEPLOY}" ]]; then
    echo "Found operator deployment from CSV: ${OPERATOR_DEPLOY}"
    oc -n "${NAMESPACE}" scale deployment "${OPERATOR_DEPLOY}" --replicas=0
    oc -n "${NAMESPACE}" wait --for=delete pod -l name="${OPERATOR_DEPLOY}" --timeout=120s 2>/dev/null || true
  else
    echo "WARNING: Could not determine operator deployment name from CSV ${CSV}" >&2
  fi
else
  echo "WARNING: Could not find installedCSV from subscription quay-operator" >&2
fi

# Find the quay-app deployment by name pattern (operator names it {registry}-quay-app)
QUAY_DEPLOY=$(oc -n "${NAMESPACE}" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep 'quay-app' | head -n1)
if [[ -z "${QUAY_DEPLOY}" ]]; then
  echo "ERROR: Could not find quay-app deployment" >&2
  exit 1
fi
echo "Found quay-app deployment: ${QUAY_DEPLOY}"

# Patch the container image
oc -n "${NAMESPACE}" set image "deployment/${QUAY_DEPLOY}" "quay-app=${QUAY_CI_IMAGE}"

# Switch entrypoint from registry-nomigrate to registry so the new image
# runs alembic migrations before starting (the operator default skips them).
oc -n "${NAMESPACE}" set env "deployment/${QUAY_DEPLOY}" QUAYENTRY=registry

# Wait for rollout
echo "Waiting for rollout of deployment/${QUAY_DEPLOY}..."
if ! oc -n "${NAMESPACE}" rollout status "deployment/${QUAY_DEPLOY}" --timeout=600s; then
  echo "ERROR: Rollout of deployment/${QUAY_DEPLOY} timed out" >&2
  collect_debug_info
  exit 1
fi

# Verify Quay health
QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute not found in SHARED_DIR" >&2
  exit 1
fi

echo "Verifying Quay health at ${QUAY_ROUTE}..."
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "${QUAY_ROUTE}/health/instance" || true)
  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "Quay is healthy after custom image swap"
    exit 0
  fi
  echo "Attempt ${i}/30: health check returned ${HTTP_CODE}, retrying..."
  sleep 10
done

echo "ERROR: Quay health check failed after image swap" >&2
collect_debug_info
exit 1
