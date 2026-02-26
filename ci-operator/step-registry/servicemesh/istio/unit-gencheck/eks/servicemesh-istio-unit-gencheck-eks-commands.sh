#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Set up kubeconfig from MAPT create step
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "[INFO] 🔧 Setting up privileged unit and gencheck test execution in EKS cluster..."

# Install kubectl for EKS cluster management (MAPT image has AWS CLI but not kubectl)
echo "[INFO] 🔧 Installing kubectl for EKS cluster management..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/ || sudo mv kubectl /usr/local/bin/ || cp kubectl /tmp/kubectl
export PATH="/usr/local/bin:/tmp:${PATH}"
echo "[SUCCESS] ✅ kubectl installed successfully"

# Set up AWS credentials for EKS authentication (AWS CLI already available in MAPT image)
echo "[INFO] 🔐 Setting up AWS credentials for EKS authentication..."
if [ -f "/tmp/secrets/.awscred" ]; then
  export AWS_SHARED_CREDENTIALS_FILE="/tmp/secrets/.awscred"
elif [ -f "/tmp/secrets/config" ]; then
  export AWS_SHARED_CREDENTIALS_FILE="/tmp/secrets/config"
else
  echo "[ERROR] ❌ AWS credentials file not found (looked for .awscred and config)"
  exit 1
fi

export AWS_REGION=${AWS_REGION:-"us-east-1"}
echo "[SUCCESS] ✅ AWS credentials configured for EKS"

# Debug kubeconfig and AWS setup (without exposing sensitive data)
echo "[INFO] 🔍 Debugging EKS connectivity setup..."
echo "[DEBUG] Kubeconfig file exists: $([ -f "${KUBECONFIG}" ] && echo "YES" || echo "NO")"
echo "[DEBUG] Kubeconfig file size: $([ -f "${KUBECONFIG}" ] && wc -c < "${KUBECONFIG}" || echo "N/A") bytes"
echo "[DEBUG] AWS credentials file exists: $([ -f "${AWS_SHARED_CREDENTIALS_FILE}" ] && echo "YES" || echo "NO")"
echo "[DEBUG] AWS region: ${AWS_REGION}"

echo "[DEBUG] Testing AWS CLI access..."
if aws sts get-caller-identity --output text --query 'Account' > /dev/null 2>&1; then
  echo "[DEBUG] ✅ AWS CLI authentication working"
else
  echo "[DEBUG] ❌ AWS CLI authentication failed"
fi

# Test kubectl connectivity with verbose output
echo "[INFO] 🔌 Testing EKS cluster connectivity..."
if ! kubectl cluster-info --request-timeout=30s; then
  echo "[ERROR] ❌ Unable to connect to EKS cluster"
  echo "[ERROR] Checking possible issues:"

  echo "[DEBUG] Testing kubectl client:"
  kubectl version --client=true > /dev/null 2>&1 || echo "kubectl client check failed"

  echo "[DEBUG] Testing kubectl server connectivity:"
  kubectl version --short=true > /dev/null 2>&1 || echo "kubectl server check failed"

  echo "[DEBUG] Checking if EKS cluster endpoint is reachable:"
  if CLUSTER_ENDPOINT=$(grep -o 'https://[^"]*\.eks\.[^"]*\.amazonaws\.com' "${KUBECONFIG}" 2>/dev/null); then
    echo "[DEBUG] Found EKS endpoint in kubeconfig"
    echo "[DEBUG] Testing basic endpoint connectivity..."
    if curl -k -m 10 "${CLUSTER_ENDPOINT}/version" > /dev/null 2>&1; then
      echo "[DEBUG] ✅ Endpoint is reachable"
    else
      echo "[DEBUG] ❌ Endpoint not reachable"
    fi
  else
    echo "[DEBUG] Could not extract EKS endpoint from kubeconfig"
  fi

  exit 1
fi
echo "[SUCCESS] ✅ EKS cluster connectivity verified"

# Create namespace with privileged pod security for OSSM tests (moved from create step)
echo "[INFO] 🔧 Setting up EKS cluster for privileged OSSM testing..."
kubectl create namespace ossm-tests || true
kubectl label namespace ossm-tests \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged || true
echo "[SUCCESS] ✅ EKS cluster configured for privileged OSSM testing"

# Generate unique names for this test run
POD_NAME="ossm-unit-gencheck-test-${BUILD_ID}"
CONTAINER_NAME="istio-builder"

# Get the MAISTRA_BUILDER_IMAGE if available, otherwise use default
BUILDER_IMAGE="gcr.io/istio-testing/build-tools:master-eebcdda8856e2d4f528991d27d4808880cce4c52"
echo "[INFO] 📦 Using builder image: ${BUILDER_IMAGE}"

# Function to cleanup resources
function cleanup() {
  echo "[INFO] 🧹 Cleaning up test resources..."

  # Temporarily disable exit on error for cleanup
  set +o errexit

  # Try to delete the pod if we can connect to the cluster
  if kubectl cluster-info --request-timeout=10s > /dev/null 2>&1; then
    echo "[INFO] 🗑️ Deleting test pod: ${POD_NAME}"
    kubectl delete pod "${POD_NAME}" -n ossm-tests --ignore-not-found=true --timeout=60s || true
    echo "[INFO] ✅ Pod cleanup completed"
  else
    echo "[WARN] ⚠️ Cannot connect to EKS cluster for cleanup, pod may be left behind"
    echo "[WARN] ⚠️ This is expected if the cluster was already destroyed"
  fi

  # Re-enable exit on error
  set -o errexit

  echo "[INFO] ✅ Cleanup completed"
}
trap cleanup EXIT

echo "[INFO] 🚀 Creating privileged pod for unit and gencheck tests..."

# Create privileged pod with required capabilities and volume mounts
kubectl apply -f - <<EOF
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
if ! kubectl wait --for=condition=Ready pod/${POD_NAME} -n ossm-tests --timeout=600s; then
  echo "[ERROR] ❌ Pod failed to become ready within 10 minutes"
  echo "[ERROR] ❌ Checking pod status for troubleshooting..."
  kubectl describe pod ${POD_NAME} -n ossm-tests || true
  kubectl logs ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} || true
  exit 1
fi
echo "[SUCCESS] ✅ Pod is ready for test execution"

echo "[INFO] 📁 Copying source code to privileged pod..."

# Create source directory in pod
echo "[INFO] 📁 Creating directories in pod..."
if ! kubectl exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- mkdir -p /tmp/istio-src /tmp/artifacts; then
  echo "[ERROR] ❌ Failed to create directories in pod"
  kubectl describe pod ${POD_NAME} -n ossm-tests || true
  exit 1
fi

# Copy entire source tree to the pod
echo "[INFO] 📦 Transferring source code..."
if ! tar czf - . | kubectl exec -i ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- tar xzf - -C /tmp/istio-src; then
  echo "[ERROR] ❌ Failed to transfer source code to pod"
  echo "[ERROR] ❌ This could indicate pod storage issues or network problems"
  kubectl describe pod ${POD_NAME} -n ossm-tests || true
  exit 1
fi
echo "[SUCCESS] ✅ Source code transferred successfully"

# ==========================================================================
# PART 1: Unit Tests
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] 🧪 PART 1: Running OSSM Istio Unit Tests"
echo "=========================================================================="

# Execute the unit tests
echo "[INFO] 🏗️ Starting unit tests in privileged pod..."
if ! kubectl exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- bash -c '
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
'; then
  echo "[ERROR] ❌ Unit tests failed"
  echo "[ERROR] ❌ Checking pod logs for troubleshooting..."
  kubectl logs ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} --tail=100 || true
  exit 1
fi

echo "[INFO] ✅ Unit tests completed successfully"

# ==========================================================================
# PART 2: GenCheck Tests
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] 🔍 PART 2: Running OSSM Istio GenCheck Tests"
echo "=========================================================================="

# Execute the gencheck tests
echo "[INFO] 🏗️ Starting gencheck tests in privileged pod..."
if ! kubectl exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- bash -c '
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
'; then
  echo "[ERROR] ❌ GenCheck tests failed"
  echo "[ERROR] ❌ Checking pod logs for troubleshooting..."
  kubectl logs ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} --tail=100 || true
  exit 1
fi

echo "[INFO] ✅ GenCheck tests completed successfully"

# ==========================================================================
# ARTIFACT COLLECTION
# ==========================================================================
echo ""
echo "=========================================================================="
echo "[INFO] 📋 Collecting Test Artifacts"
echo "=========================================================================="

# Copy any artifacts back from the pod
kubectl exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- find /tmp/artifacts -type f 2>/dev/null || true
if kubectl exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- ls /tmp/artifacts/ 2>/dev/null | grep -q .; then
  echo "[INFO] 📄 Copying artifacts..."
  kubectl exec ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} -- tar czf - -C /tmp/artifacts . | tar xzf - -C "${ARTIFACT_DIR:-/tmp/artifacts}" 2>/dev/null || true
fi

# Copy comprehensive logs
kubectl logs ${POD_NAME} -n ossm-tests -c ${CONTAINER_NAME} > "${ARTIFACT_DIR:-/tmp}/unit-gencheck-combined-logs.txt" || true

echo ""
echo "=========================================================================="
echo "[SUCCESS] ✅ OSSM Istio Unit + GenCheck tests completed successfully in shared EKS cluster"
echo "=========================================================================="