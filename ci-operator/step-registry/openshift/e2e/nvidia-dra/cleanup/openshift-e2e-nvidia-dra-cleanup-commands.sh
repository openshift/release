#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "NVIDIA DRA Test Cleanup"
echo "========================================="

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if Helm is available
if ! command_exists helm; then
  echo "WARNING: Helm not found, skipping Helm uninstall steps"
  HELM_AVAILABLE=false
else
  HELM_AVAILABLE=true
fi

# Uninstall NVIDIA DRA Driver
echo "Uninstalling NVIDIA DRA Driver..."
if [ "${HELM_AVAILABLE}" = true ]; then
  helm uninstall nvidia-dra-driver-gpu \
    --namespace nvidia-dra-driver-gpu \
    --wait \
    --timeout 5m 2>/dev/null || echo "  (already uninstalled or not found)"
else
  echo "  Skipping Helm uninstall (Helm not available)"
fi

# Clean up SCC permissions (ClusterRoleBindings)
echo "Cleaning up SCC permissions..."
for crb in \
  nvidia-dra-privileged-nvidia-dra-driver-gpu-service-account-controller \
  nvidia-dra-privileged-nvidia-dra-driver-gpu-service-account-kubeletplugin \
  nvidia-dra-privileged-compute-domain-daemon-service-account; do
  oc delete clusterrolebinding "$crb" --ignore-not-found=true 2>/dev/null && \
    echo "  Deleted ClusterRoleBinding: $crb" || true
done

# Delete DRA Driver namespace
echo "Deleting nvidia-dra-driver-gpu namespace..."
oc delete namespace nvidia-dra-driver-gpu --ignore-not-found=true --wait=false 2>/dev/null || true

# Uninstall GPU Operator
echo "Uninstalling GPU Operator..."
if [ "${HELM_AVAILABLE}" = true ]; then
  helm uninstall gpu-operator \
    --namespace nvidia-gpu-operator \
    --wait \
    --timeout 5m 2>/dev/null || echo "  (already uninstalled or not found)"
else
  echo "  Skipping Helm uninstall (Helm not available)"
fi

# Delete GPU Operator namespace
echo "Deleting nvidia-gpu-operator namespace..."
oc delete namespace nvidia-gpu-operator --ignore-not-found=true --wait=false 2>/dev/null || true

# Clean up test resources
echo "Cleaning up test resources..."

# Delete any test DeviceClasses (these are cluster-scoped)
TEST_DEVICECLASSES=$(oc get deviceclass -o name 2>/dev/null | grep -E 'test-nvidia' || true)
if [ -n "$TEST_DEVICECLASSES" ]; then
  echo "  Deleting test DeviceClasses..."
  echo "$TEST_DEVICECLASSES" | xargs -r oc delete --ignore-not-found=true 2>/dev/null || true
fi

# Delete any test namespaces
TEST_NAMESPACES=$(oc get namespaces -o name 2>/dev/null | grep -E 'nvidia-dra.*test|e2e.*nvidia' || true)
if [ -n "$TEST_NAMESPACES" ]; then
  echo "  Deleting test namespaces..."
  echo "$TEST_NAMESPACES" | xargs -r oc delete --wait=false --ignore-not-found=true 2>/dev/null || true
fi

echo ""
echo "========================================="
echo "Cleanup Complete"
echo "========================================="
echo "NOTE: GPU node labels managed by NFD will be removed automatically"
echo "NOTE: ResourceSlices will be cleaned up by the Kubernetes API server"
