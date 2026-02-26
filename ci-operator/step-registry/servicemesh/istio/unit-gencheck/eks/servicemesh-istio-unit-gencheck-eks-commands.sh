#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Set up kubeconfig from MAPT create step
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "[INFO] 🔧 Setting up privileged unit and gencheck test execution in EKS cluster..."

# Generate unique names for this test run
POD_NAME="ossm-unit-gencheck-test-${BUILD_ID}"
CONTAINER_NAME="istio-builder"

# Get the MAISTRA_BUILDER_IMAGE if available, otherwise use default
BUILDER_IMAGE="${MAISTRA_BUILDER_IMAGE:-quay-proxy.ci.openshift.org/openshift/ci:ci_maistra-builder_upstream-master}"
echo "[INFO] 📦 Using builder image: ${BUILDER_IMAGE}"

# Function to cleanup resources
function cleanup() {
  echo "[INFO] 🧹 Cleaning up test resources..."
  oc delete pod "${POD_NAME}" -n ossm-tests --ignore-not-found=true || true
  echo "[INFO] ✅ Cleanup completed"
}
trap cleanup EXIT

echo "[INFO] 🚀 Creating privileged pod for unit and gencheck tests..."

# Create privileged pod with required capabilities and volume mounts
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ossm-tests
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
  - name: ${CONTAINER_NAME}
    image: ${BUILDER_IMAGE}
    command: ["/bin/bash"]
    args: ["-c", "sleep 7200"]
    securityContext:
      privileged: true
      runAsUser: 0
      capabilities:
        add:
        - IPC_LOCK
        - SYS_ADMIN
    env:
    - name: BUILD_WITH_CONTAINER
      value: "0"
    - name: GOBIN
      value: "/gobin"
    - name: GOCACHE
      value: "/tmp/cache"
    - name: GOMODCACHE
      value: "/tmp/cache"
    - name: XDG_CACHE_HOME
      value: "/tmp/cache"
    - name: T
      value: "-v"
    - name: ARTIFACTS
      value: "/tmp/artifacts"
    volumeMounts:
    - name: kernel-modules
      mountPath: /lib/modules
      readOnly: true
    - name: docker-storage
      mountPath: /var/lib/docker
    - name: proc
      mountPath: /host/proc
      readOnly: true
    - name: sys
      mountPath: /host/sys
      readOnly: true
    workingDir: /tmp/istio-src
  volumes:
  - name: kernel-modules
    hostPath:
      path: /lib/modules
      type: Directory
  - name: docker-storage
    emptyDir: {}
  - name: proc
    hostPath:
      path: /proc
      type: Directory
  - name: sys
    hostPath:
      path: /sys
      type: Directory
EOF

echo "[INFO] ⏳ Waiting for pod to be ready..."
oc wait --for=condition=Ready pod/${POD_NAME} -n ossm-tests --timeout=600s

echo "[INFO] 📁 Copying source code to privileged pod..."

# Create source directory in pod
oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- mkdir -p /tmp/istio-src
oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- mkdir -p /tmp/artifacts

# Copy entire source tree to the pod
echo "[INFO] 📦 Transferring source code..."
tar czf - . | oc exec -i ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- tar xzf - -C /tmp/istio-src

# ==========================================================================
# PART 1: Unit Tests
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] 🧪 PART 1: Running OSSM Istio Unit Tests"
echo "=========================================================================="

# Execute the unit tests
oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- bash -c '
  set -euo pipefail
  cd /tmp/istio-src

  echo "[INFO] 🏗️ Starting unit tests: make -e BUILD_WITH_CONTAINER=0 T=-v build racetest binaries-test"

  # Run the actual unit tests
  make -e BUILD_WITH_CONTAINER=0 T=-v build racetest binaries-test

  echo "[SUCCESS] ✅ Unit tests completed successfully"

  # Save unit test artifacts with prefix
  if [ -d "out" ]; then
    mkdir -p /tmp/artifacts/unit
    cp -r out/* /tmp/artifacts/unit/ 2>/dev/null || true
  fi
'

echo "[INFO] ✅ Unit tests completed successfully"

# ==========================================================================
# PART 2: GenCheck Tests
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] 🔍 PART 2: Running OSSM Istio GenCheck Tests"
echo "=========================================================================="

# Execute the gencheck tests
oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- bash -c '
  set -euo pipefail
  cd /tmp/istio-src

  echo "[INFO] 🏗️ Starting gencheck tests: make gen-check BUILD_WITH_CONTAINER=0"

  # Run the actual gencheck tests
  make gen-check \
    ARTIFACTS="${ARTIFACTS}" \
    BUILD_WITH_CONTAINER="0" \
    GOBIN="/gobin" \
    GOCACHE="/tmp/cache" \
    GOMODCACHE="/tmp/cache" \
    XDG_CACHE_HOME="/tmp/cache"

  echo "[SUCCESS] ✅ GenCheck tests completed successfully"

  # Save gencheck artifacts with prefix
  if [ -d "out" ]; then
    mkdir -p /tmp/artifacts/gencheck
    cp -r out/* /tmp/artifacts/gencheck/ 2>/dev/null || true
  fi
'

echo "[INFO] ✅ GenCheck tests completed successfully"

# ==========================================================================
# ARTIFACT COLLECTION
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] 📋 Collecting Test Artifacts"
echo "=========================================================================="

# Copy any artifacts back from the pod
oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- find /tmp/artifacts -type f 2>/dev/null || true
if oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- ls /tmp/artifacts/ 2>/dev/null | grep -q .; then
  echo "[INFO] 📄 Copying artifacts..."
  oc exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- tar czf - -C /tmp/artifacts . | tar xzf - -C "${ARTIFACT_DIR:-/tmp/artifacts}" 2>/dev/null || true
fi

# Copy comprehensive logs
oc logs ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} > "${ARTIFACT_DIR:-/tmp}/unit-gencheck-combined-logs.txt" || true

echo ""
echo "=========================================================================="
echo "[SUCCESS] ✅ OSSM Istio Unit + GenCheck tests completed successfully in shared EKS cluster"
echo "=========================================================================="