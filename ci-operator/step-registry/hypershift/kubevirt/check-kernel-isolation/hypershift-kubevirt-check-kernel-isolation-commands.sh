#!/bin/bash

set -euo pipefail

echo "=========================================="
echo "Checking Kernel Isolation Between Management and Hosted Clusters"
echo "=========================================="
echo ""

# Install oc CLI if not available
if ! command -v oc &> /dev/null; then
    echo "Installing oc CLI..."
    cd /tmp
    curl -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/openshift-client-linux.tar.gz | tar xzf -
    chmod +x oc kubectl
    export PATH="/tmp:${PATH}"
    echo "oc CLI installed successfully"
    oc version --client || true
    echo ""
fi

CLUSTER_NAME=$(echo -n "${PROW_JOB_ID}"|sha256sum|cut -c-20)
MGMT_KUBECONFIG="${KUBECONFIG}"

# Function to get kernel info from a node using node status (no oc debug needed)
get_kernel_info() {
  local KUBECONFIG_PATH=$1
  local LABEL_SELECTOR=$2
  local CONTEXT_NAME=$3

  echo "--- Getting kernel info for $CONTEXT_NAME ---"

  export KUBECONFIG="$KUBECONFIG_PATH"

  # Wait for at least one node to be ready
  echo "Waiting for nodes to be ready..."
  timeout 300 bash -c "until oc get nodes -l \"$LABEL_SELECTOR\" 2>/dev/null | grep -q Ready; do sleep 5; done" || {
    echo "ERROR: No ready nodes found for $CONTEXT_NAME"
    oc get nodes || true
    return 1
  }

  # Get the first ready node
  local NODE
  NODE=$(oc get nodes -l "$LABEL_SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "$NODE" ]]; then
    echo "ERROR: Could not find node for $CONTEXT_NAME"
    return 1
  fi

  echo "Using node: $NODE"

  # Get kernel version from node status
  local KERNEL
  KERNEL=$(oc get node "$NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null)
  echo "Kernel version: $KERNEL"

  # Get boot ID from node status (unique per kernel instance)
  local BOOT_ID
  BOOT_ID=$(oc get node "$NODE" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null)
  echo "Boot ID: $BOOT_ID"

  # Get OS image from node status
  local OS_IMAGE
  OS_IMAGE=$(oc get node "$NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null)
  echo "OS Image: $OS_IMAGE"

  # Return values via global variables
  eval "${CONTEXT_NAME}_KERNEL='$KERNEL'"
  eval "${CONTEXT_NAME}_BOOT_ID='$BOOT_ID'"
  eval "${CONTEXT_NAME}_OS_IMAGE='$OS_IMAGE'"

  echo ""
}

# Get management cluster kernel info
echo "=== Management Cluster Kernel Info ==="
# Try worker nodes first, then master nodes if no workers found
get_kernel_info "$KUBECONFIG" "node-role.kubernetes.io/worker=" "MGMT" || \
get_kernel_info "$KUBECONFIG" "node-role.kubernetes.io/master=" "MGMT" || \
get_kernel_info "$KUBECONFIG" "node-role.kubernetes.io/control-plane=" "MGMT" || {
  echo "ERROR: Failed to get management cluster kernel info"
  exit 1
}

# Use nested_kubeconfig from SHARED_DIR (created by previous steps)
echo "=== Hosted Cluster Kernel Info (Guest VM) ==="
HOSTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

if [[ ! -f "$HOSTED_KUBECONFIG" ]]; then
  echo "ERROR: Hosted cluster kubeconfig not found at $HOSTED_KUBECONFIG"
  echo "Expected location: ${SHARED_DIR}/nested_kubeconfig"
  echo "Files in ${SHARED_DIR}:"
  ls -la "${SHARED_DIR}" || true
  exit 1
fi

echo "Using hosted cluster kubeconfig: $HOSTED_KUBECONFIG"
get_kernel_info "$HOSTED_KUBECONFIG" "node-role.kubernetes.io/worker=" "HOSTED" || {
  echo "ERROR: Failed to get hosted cluster kernel info"
  exit 1
}

# Verify VM boundaries - switch back to management cluster kubeconfig
echo "=== Verifying VM Boundaries ==="
export KUBECONFIG="${MGMT_KUBECONFIG}"

# Find the control plane namespace (VirtLauncher pods run there, not in the hosted cluster namespace)
echo "Looking for VirtLauncher pods in namespaces matching ${CLUSTER_NAME}..."

# Wait for VirtLauncher pods to appear (they may take time to start)
CONTROL_PLANE_NS=""
for i in {1..60}; do
  CONTROL_PLANE_NS=$(oc get pods -A --no-headers 2>/dev/null | grep virt-launcher | grep "${CLUSTER_NAME}" | head -1 | awk '{print $1}' || echo "")
  if [[ -n "$CONTROL_PLANE_NS" ]]; then
    break
  fi
  echo "Waiting for VirtLauncher pods to appear (attempt $i/60)..."
  sleep 5
done

if [[ -z "$CONTROL_PLANE_NS" ]]; then
  echo "ERROR: Could not find control plane namespace with VirtLauncher pods after 5 minutes!"
  echo "Searching for namespaces containing ${CLUSTER_NAME}:"
  oc get namespaces | grep "${CLUSTER_NAME}" || true
  echo ""
  echo "Searching for any VirtLauncher pods:"
  oc get pods -A | grep virt-launcher || true
  echo ""
  echo "All namespaces:"
  oc get namespaces || true
  exit 1
fi

echo "Found control plane namespace: ${CONTROL_PLANE_NS}"

echo "Checking for VirtLauncher pods..."
VIRT_LAUNCHER_COUNT=$(oc get pods -n "${CONTROL_PLANE_NS}" --no-headers 2>/dev/null | grep -c virt-launcher || echo "0")
VIRT_LAUNCHER_COUNT=$(echo "$VIRT_LAUNCHER_COUNT" | tr -d '\r\n' | head -1)
if [[ "$VIRT_LAUNCHER_COUNT" -eq 0 ]]; then
  echo "ERROR: No VirtLauncher pods found in namespace ${CONTROL_PLANE_NS}!"
  echo "Available pods:"
  oc get pods -n "${CONTROL_PLANE_NS}" || true
  exit 1
fi
echo "PASS: Found $VIRT_LAUNCHER_COUNT VirtLauncher pod(s)"

echo "Checking for VirtualMachineInstance resources..."
VMI_COUNT=$(oc get vmi -n "${CONTROL_PLANE_NS}" --no-headers 2>/dev/null | wc -l || echo "0")
VMI_COUNT=$(echo "$VMI_COUNT" | tr -d '\r\n' | head -1)
if [[ "$VMI_COUNT" -eq 0 ]]; then
  echo "ERROR: No VirtualMachineInstance resources found in namespace ${CONTROL_PLANE_NS}!"
  echo "Available VMIs:"
  oc get vmi -A || true
  exit 1
fi
echo "PASS: Found $VMI_COUNT VirtualMachineInstance resource(s)"

# Verify NetworkPolicy
echo ""
echo "=== Verifying VirtLauncher NetworkPolicy ==="
if oc get networkpolicy -n "${CONTROL_PLANE_NS}" -o yaml 2>/dev/null | grep -q virt-launcher; then
  echo "PASS: VirtLauncher NetworkPolicy found"
else
  echo "WARNING: VirtLauncher NetworkPolicy not found"
  echo "Available NetworkPolicies:"
  oc get networkpolicy -n "${CONTROL_PLANE_NS}" || true
fi

# Compare kernel isolation
echo ""
echo "=========================================="
echo "Kernel Isolation Analysis"
echo "=========================================="

echo ""
echo "Management Cluster:"
echo "  Kernel:   $MGMT_KERNEL"
echo "  Boot ID:  $MGMT_BOOT_ID"
echo "  OS Image: $MGMT_OS_IMAGE"

echo ""
echo "Hosted Cluster (Guest VM):"
echo "  Kernel:   $HOSTED_KERNEL"
echo "  Boot ID:  $HOSTED_BOOT_ID"
echo "  OS Image: $HOSTED_OS_IMAGE"

echo ""
echo "--- Boot ID Comparison (Critical Test) ---"
if [[ "$MGMT_BOOT_ID" == "$HOSTED_BOOT_ID" ]]; then
  echo "FAIL: Management and hosted clusters have the SAME boot ID!"
  echo "   Management Boot ID: $MGMT_BOOT_ID"
  echo "   Hosted Boot ID:     $HOSTED_BOOT_ID"
  echo ""
  echo "This indicates they may be sharing the same kernel (NO TRUE VM ISOLATION)"
  echo "This violates ANSSI BP-028 requirements for kernel-level isolation."
  exit 1
fi

echo "PASS: Different boot IDs confirm separate kernel instances"
echo "   Management Boot ID: $MGMT_BOOT_ID"
echo "   Hosted Boot ID:     $HOSTED_BOOT_ID"

echo ""
echo "--- Kernel Version Comparison (Informational) ---"
if [[ "$MGMT_KERNEL" == "$HOSTED_KERNEL" ]]; then
  echo "NOTICE: Same kernel version string detected"
  echo "   Management: $MGMT_KERNEL"
  echo "   Hosted:     $HOSTED_KERNEL"
  echo "   This is acceptable - both may use the same RHCOS release"
  echo "   VM isolation is still confirmed by different boot IDs"
else
  echo "PASS: Different kernel versions detected"
  echo "   Management: $MGMT_KERNEL"
  echo "   Hosted:     $HOSTED_KERNEL"
  echo "   This provides additional evidence of version skew working correctly"
fi

echo ""
echo "=========================================="
echo "Kernel Isolation Check: PASSED"
echo "=========================================="
echo ""
echo "Summary:"
echo "  VM Isolation:     Confirmed (VirtLauncher pods: $VIRT_LAUNCHER_COUNT, VMIs: $VMI_COUNT)"
echo "  Kernel Isolation: Confirmed (different boot IDs)"
echo "  ANSSI BP-028:     Validated (kernel-level isolation)"
echo ""
echo "Management Kernel: $MGMT_KERNEL (Boot ID: ${MGMT_BOOT_ID:0:8}...)"
echo "Hosted Kernel:     $HOSTED_KERNEL (Boot ID: ${HOSTED_BOOT_ID:0:8}...)"
echo ""
