#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "NVIDIA DRA Driver Installation via Helm"
echo "========================================="
echo "Version: ${NVIDIA_DRA_DRIVER_VERSION}"
echo "Namespace: ${NVIDIA_DRA_DRIVER_NAMESPACE}"
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Verify GPU Operator is installed first
echo "Verifying GPU Operator is installed..."
if ! oc get clusterpolicy gpu-cluster-policy &>/dev/null; then
  echo "ERROR: GPU Operator ClusterPolicy not found!"
  echo "Please ensure GPU Operator is installed before running this step"
  exit 1
fi

# Check CDI is enabled
CDI_ENABLED=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.cdi.enabled}' 2>/dev/null || echo "false")
if [ "${CDI_ENABLED}" != "true" ]; then
  echo "ERROR: CDI is not enabled in GPU Operator ClusterPolicy"
  echo "DRA requires CDI to be enabled"
  exit 1
fi

echo "✓ GPU Operator is installed with CDI enabled"
echo ""

# Check if DRA driver is already installed
if oc get namespace "${NVIDIA_DRA_DRIVER_NAMESPACE}" &>/dev/null; then
  echo "INFO: ${NVIDIA_DRA_DRIVER_NAMESPACE} namespace already exists"
  if helm list -n "${NVIDIA_DRA_DRIVER_NAMESPACE}" 2>/dev/null | grep -q nvidia-dra-driver; then
    echo "INFO: NVIDIA DRA driver is already installed"
    INSTALLED_VERSION=$(helm list -n "${NVIDIA_DRA_DRIVER_NAMESPACE}" -o json | jq -r '.[] | select(.name=="nvidia-dra-driver") | .app_version')
    echo "Installed version: ${INSTALLED_VERSION}"
    echo "Skipping installation"
    exit 0
  fi
fi

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.14.0"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mv /tmp/linux-amd64/helm /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  echo "✓ Helm installed: $(helm version --short)"
else
  echo "✓ Helm already installed: $(helm version --short)"
fi

echo ""

# Create namespace
echo "Creating namespace ${NVIDIA_DRA_DRIVER_NAMESPACE}..."
oc create namespace "${NVIDIA_DRA_DRIVER_NAMESPACE}" || true
oc label namespace "${NVIDIA_DRA_DRIVER_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite

# Add NVIDIA Helm repository
echo "Adding NVIDIA Helm repository..."
helm repo add nvidia https://nvidia.github.io/k8s-dra-driver || true
helm repo update

echo ""

# Prepare feature gate arguments
FEATURE_GATE_ARGS=""
if [ -n "${NVIDIA_DRA_FEATURE_GATES:-}" ]; then
  echo "Feature gates: ${NVIDIA_DRA_FEATURE_GATES}"
  # Convert comma-separated key=value pairs to --set featureGates.key=value
  IFS=',' read -ra GATES <<< "${NVIDIA_DRA_FEATURE_GATES}"
  for gate in "${GATES[@]}"; do
    # Split on = to get key and value
    key="${gate%%=*}"
    value="${gate#*=}"
    FEATURE_GATE_ARGS="${FEATURE_GATE_ARGS} --set featureGates.${key}=${value}"
  done
  echo "Helm feature gate arguments: ${FEATURE_GATE_ARGS}"
fi

echo ""

# Install NVIDIA DRA driver
echo "Installing NVIDIA DRA driver v${NVIDIA_DRA_DRIVER_VERSION}..."
helm install nvidia-dra-driver nvidia/k8s-dra-driver \
  --namespace "${NVIDIA_DRA_DRIVER_NAMESPACE}" \
  --version "${NVIDIA_DRA_DRIVER_VERSION}" \
  --set nfd.enabled=false \
  --set gfd.enabled=false \
  ${FEATURE_GATE_ARGS} \
  --wait \
  --timeout 10m

echo ""
echo "✓ NVIDIA DRA driver installed successfully"

# Wait for DRA driver pods to be ready
echo ""
echo "Waiting for DRA driver pods to be ready..."
oc wait --for=condition=Ready pods \
  --all \
  -n "${NVIDIA_DRA_DRIVER_NAMESPACE}" \
  --timeout=10m

echo "✓ All DRA driver pods are ready"

# List pods
echo ""
echo "DRA driver pods:"
oc get pods -n "${NVIDIA_DRA_DRIVER_NAMESPACE}"

# Wait for DeviceClass to be created
echo ""
echo "Waiting for DeviceClass to be created..."
timeout 5m bash -c '
while true; do
  if oc get deviceclass nvidia.com/gpu &>/dev/null; then
    echo "✓ DeviceClass created: nvidia.com/gpu"
    break
  fi
  echo "Waiting for DeviceClass..."
  sleep 10
done
'

# Show DeviceClass
echo ""
echo "DeviceClass details:"
oc get deviceclass nvidia.com/gpu -o yaml

# Verify ResourceSlices are created for GPU nodes
echo ""
echo "Checking ResourceSlices..."
RESOURCE_SLICES=$(oc get resourceslice -o name 2>/dev/null | wc -l)
echo "Found ${RESOURCE_SLICES} ResourceSlice(s)"

if [ "${RESOURCE_SLICES}" -gt 0 ]; then
  echo ""
  echo "ResourceSlices:"
  oc get resourceslice
fi

echo ""
echo "========================================="
echo "NVIDIA DRA Driver Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: ${NVIDIA_DRA_DRIVER_NAMESPACE}"
echo "  - Version: ${NVIDIA_DRA_DRIVER_VERSION}"
echo "  - DeviceClass: nvidia.com/gpu"
echo "  - ResourceSlices: ${RESOURCE_SLICES}"
echo ""
