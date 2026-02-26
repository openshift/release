#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Set up kubeconfig from MAPT create step
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "[INFO] SETUP Setting up OSSM Istio unit and gencheck test execution in OpenShift SNC cluster..."

# Read namespace and pod information from pod-setup step
echo "[INFO] READ Reading pod configuration from shared directory..."

if [[ ! -f "${SHARED_DIR}/ossm-namespace" ]]; then
  echo "[ERROR] ERROR Namespace file not found at ${SHARED_DIR}/ossm-namespace"
  echo "[ERROR] ERROR Pod setup step may have failed or not run"
  exit 1
fi

if [[ ! -f "${SHARED_DIR}/ossm-pod-name" ]]; then
  echo "[ERROR] ERROR Pod name file not found at ${SHARED_DIR}/ossm-pod-name"
  echo "[ERROR] ERROR Pod setup step may have failed or not run"
  exit 1
fi

NAMESPACE=$(cat "${SHARED_DIR}/ossm-namespace")
POD_NAME=$(cat "${SHARED_DIR}/ossm-pod-name")
CONTAINER_NAME="testpod"

echo "[SUCCESS] !!!! Retrieved pod configuration:"
echo "[INFO] NOTE Namespace: ${NAMESPACE}"
echo "[INFO] NOTE Pod: ${POD_NAME}"
echo "[INFO] NOTE Container: ${CONTAINER_NAME}"

# Test OpenShift connectivity
echo "[INFO] CONNECT Testing OpenShift SNC cluster connectivity..."
if ! oc cluster-info --request-timeout=30s > /dev/null; then
  echo "[ERROR] ERROR Unable to connect to OpenShift SNC cluster"
  echo "[ERROR] ERROR Kubeconfig file: ${KUBECONFIG}"
  exit 1
fi
echo "[SUCCESS] !!!! OpenShift SNC cluster connectivity verified"

# Verify pod is still running and ready
echo "[INFO] CHECK Verifying pod status before test execution..."
if ! oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' | grep -q "Running"; then
  echo "[ERROR] ERROR Pod ${POD_NAME} is not in Running state"
  oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide
  oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
  exit 1
fi

if ! oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q "true"; then
  echo "[ERROR] ERROR Pod ${POD_NAME} container is not ready"
  oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
  exit 1
fi
echo "[SUCCESS] !!!! Pod is running and ready for test execution"

# Function to cleanup resources on failure
function cleanup() {
  echo "[INFO] **** Collecting logs for troubleshooting..."

  # Temporarily disable exit on error for cleanup
  set +o errexit

  # Try to collect logs and pod status
  if oc cluster-info --request-timeout=10s > /dev/null 2>&1; then
    echo "[INFO] INFO Collecting pod logs..."
    oc logs "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" --tail=200 > "${ARTIFACT_DIR:-/tmp}/pod-logs.txt" || true
    echo "[INFO] INFO Collecting pod describe output..."
    oc describe pod "${POD_NAME}" -n "${NAMESPACE}" > "${ARTIFACT_DIR:-/tmp}/pod-describe.txt" || true
  else
    echo "[WARN] WARN Cannot connect to OpenShift cluster for log collection"
  fi

  # Re-enable exit on error
  set -o errexit

  echo "[INFO] !!!! Cleanup completed"
}
trap cleanup EXIT

# ==========================================================================
# PART 1: Unit Tests
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] TEST PART 1: Running OSSM Istio Unit Tests"
echo "=========================================================================="

# Execute the unit tests
echo "[INFO] BUILD Starting unit tests in privileged OpenShift pod..."
if ! oc exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- bash -c '
  set -euo pipefail
  cd /work

  echo "[INFO] BUILD Starting unit tests: make -e BUILD_WITH_CONTAINER=0 T=-v build racetest binaries-test"

  # Run the actual unit tests
  make -e BUILD_WITH_CONTAINER=0 T=-v build racetest binaries-test

  echo "[SUCCESS] !!!! Unit tests completed successfully"

  # Save unit test artifacts with prefix
  if [ -d "out" ]; then
    mkdir -p /tmp/artifacts/unit
    cp -r out/* /tmp/artifacts/unit/ 2>/dev/null || true
  fi
'; then
  echo "[ERROR] ERROR Unit tests failed"
  echo "[ERROR] ERROR Checking pod logs for troubleshooting..."
  oc logs "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" --tail=100 || true
  exit 1
fi

echo "[SUCCESS] !!!! Unit tests completed successfully"

# ==========================================================================
# PART 2: GenCheck Tests
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] CHECK PART 2: Running OSSM Istio GenCheck Tests"
echo "=========================================================================="

# Execute the gencheck tests
echo "[INFO] BUILD Starting gencheck tests in privileged OpenShift pod..."
if ! oc exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- bash -c '
  set -euo pipefail
  cd /work

  echo "[INFO] BUILD Starting gencheck tests: make gen-check BUILD_WITH_CONTAINER=0"

  # Run the actual gencheck tests
  make gen-check \
    ARTIFACTS="/tmp/artifacts" \
    BUILD_WITH_CONTAINER="0" \
    GOBIN="/gobin" \
    GOCACHE="/tmp/cache" \
    GOMODCACHE="/tmp/cache" \
    XDG_CACHE_HOME="/tmp/cache"

  echo "[SUCCESS] !!!! GenCheck tests completed successfully"

  # Save gencheck artifacts with prefix
  if [ -d "out" ]; then
    mkdir -p /tmp/artifacts/gencheck
    cp -r out/* /tmp/artifacts/gencheck/ 2>/dev/null || true
  fi
'; then
  echo "[ERROR] ERROR GenCheck tests failed"
  echo "[ERROR] ERROR Checking pod logs for troubleshooting..."
  oc logs "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" --tail=100 || true
  exit 1
fi

echo "[SUCCESS] !!!! GenCheck tests completed successfully"

# ==========================================================================
# ARTIFACT COLLECTION
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] INFO Collecting Test Artifacts"
echo "=========================================================================="

# Copy any artifacts back from the pod
echo "[INFO] FILE Checking for artifacts in pod..."
if oc exec "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" -- ls /tmp/artifacts/ 2>/dev/null | grep -q .; then
  echo "[INFO] FILE Copying artifacts using oc cp..."
  oc cp "${NAMESPACE}"/"${POD_NAME}":/tmp/artifacts/. "${ARTIFACT_DIR:-/tmp/artifacts}/" 2>/dev/null || true
else
  echo "[INFO] FILE No artifacts found in /tmp/artifacts/"
fi

# Copy comprehensive logs
echo "[INFO] INFO Collecting comprehensive logs..."
oc logs "${POD_NAME}" -n "${NAMESPACE}" -c "${CONTAINER_NAME}" > "${ARTIFACT_DIR:-/tmp}/unit-gencheck-combined-logs.txt" || true

# Additional debug information
echo "[INFO] CHECK Collecting pod debug information..."
oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o yaml > "${ARTIFACT_DIR:-/tmp}/pod-spec.yaml" || true
oc describe pod "${POD_NAME}" -n "${NAMESPACE}" > "${ARTIFACT_DIR:-/tmp}/pod-describe.txt" || true

echo ""
echo "=========================================================================="
echo "[SUCCESS] !!!! OSSM Istio Unit + GenCheck tests completed successfully in OpenShift SNC cluster"
echo "=========================================================================="
echo "[INFO] NOTE Namespace: ${NAMESPACE}"
echo "[INFO] NOTE Pod: ${POD_NAME}"
echo "[INFO] FILE Artifacts saved to: ${ARTIFACT_DIR:-/tmp}"