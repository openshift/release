#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "NVIDIA DRA Test Cleanup"
echo "========================================="

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# ===================================================
# MUST-GATHER COLLECTION (before cleanup)
# Using the same scripts as the ecosystem team
# ===================================================
echo ""
echo "Collecting NFD and GPU operator must-gather (ecosystem team's approach)..."
echo ""

# Create must-gather directories
NFD_ARTIFACT_DIR="${ARTIFACT_DIR}/nfd-must-gather"
GPU_ARTIFACT_DIR="${ARTIFACT_DIR}/gpu-must-gather"
mkdir -p "${NFD_ARTIFACT_DIR}"
mkdir -p "${GPU_ARTIFACT_DIR}"

# Download and run NFD must-gather script (same as ecosystem team)
NFD_RELEASE_BRANCH="${NFD_RELEASE_BRANCH:-release-4.22}"
echo "Downloading NFD must-gather from ${NFD_RELEASE_BRANCH}..."
if curl -sL "https://raw.githubusercontent.com/openshift/cluster-nfd-operator/refs/heads/${NFD_RELEASE_BRANCH}/must-gather/gather" -o /tmp/nfd-must-gather.sh; then
  chmod +x /tmp/nfd-must-gather.sh
  echo "Running NFD must-gather..."
  /tmp/nfd-must-gather.sh "${NFD_ARTIFACT_DIR}" || echo "NFD must-gather failed, continuing..."
else
  echo "WARNING: Failed to download NFD must-gather script"
fi

# Download and run GPU operator must-gather script (same as ecosystem team)
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.10.1}"
echo "Downloading GPU operator must-gather from ${GPU_OPERATOR_VERSION}..."
if curl -sL "https://raw.githubusercontent.com/NVIDIA/gpu-operator/${GPU_OPERATOR_VERSION}/hack/must-gather.sh" -o /tmp/gpu-must-gather.sh; then
  chmod +x /tmp/gpu-must-gather.sh
  echo "Running GPU operator must-gather..."
  /tmp/gpu-must-gather.sh -d "${GPU_ARTIFACT_DIR}" || echo "GPU must-gather failed, continuing..."
else
  echo "WARNING: Failed to download GPU operator must-gather script"
fi

# Also collect ClusterPolicy directly (critical for DTK debugging)
echo "Collecting ClusterPolicy for easy reference..."
oc get clusterpolicy -o yaml > "${ARTIFACT_DIR}/cluster_policy.yaml" 2>&1 || echo "No ClusterPolicy found" > "${ARTIFACT_DIR}/cluster_policy.yaml"

echo ""
echo "Must-gather collection complete."
echo "Artifacts saved to:"
echo "  - ${NFD_ARTIFACT_DIR}"
echo "  - ${GPU_ARTIFACT_DIR}"
echo "  - ${ARTIFACT_DIR}/cluster_policy.yaml (ClusterPolicy for quick reference)"
echo ""

# ===================================================
# CLEANUP (after collecting diagnostics)
# ===================================================

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

# Delete NodeFeatureDiscovery CR
echo "Deleting NodeFeatureDiscovery CR..."
oc delete nodefeaturediscovery --all -n openshift-nfd --ignore-not-found=true --wait=false 2>/dev/null || true

# Delete NFD Operator subscription and CSV
echo "Deleting NFD Operator subscription and CSV..."
oc delete subscription nfd -n openshift-nfd --ignore-not-found=true 2>/dev/null || true
NFD_CSV=$(oc get csv -n openshift-nfd -o name 2>/dev/null | grep -i nfd | head -1 || true)
if [ -n "$NFD_CSV" ]; then
  oc delete "$NFD_CSV" -n openshift-nfd --ignore-not-found=true 2>/dev/null || true
fi

# Delete NFD namespace
echo "Deleting openshift-nfd namespace..."
oc delete namespace openshift-nfd --ignore-not-found=true --wait=false 2>/dev/null || true

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
