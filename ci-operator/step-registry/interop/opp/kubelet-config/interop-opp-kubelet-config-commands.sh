#!/bin/bash
# ---------------------------------------------------------------------------
# OPP kubelet eviction threshold tuning
#
# Applies a KubeletConfig CR to lower the ephemeral-storage eviction
# thresholds on worker nodes.  The default kubelet threshold evicts
# pods when nodefs.available drops below 10 % of the root filesystem.
# On RHCOS the root FS is typically ~23 GiB regardless of the
# underlying EBS volume size (known issue OCPBUGS-15087), so the
# default 10 % threshold (~2.3 GiB) fires prematurely.
#
# This step sets:
#   evictionHard:  nodefs.available=500Mi, imagefs.available=500Mi
#   evictionSoft:  nodefs.available=1Gi,   imagefs.available=1Gi
#   evictionSoftGracePeriod: 1m for both
#
# After applying the CR it waits for the worker MachineConfigPool to
# finish rolling out the new configuration.
#
# The CI cluster is ephemeral -- lowering thresholds is safe here.
# ---------------------------------------------------------------------------

set -euo pipefail

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

MCP_TIMEOUT="${MCP_TIMEOUT:-1200}"

echo "=== OPP Kubelet Eviction Threshold Tuning ==="

# Check if a KubeletConfig with this name already exists
if oc get kubeletconfig opp-ephemeral-threshold -o name 2>/dev/null; then
    echo "KubeletConfig opp-ephemeral-threshold already exists -- skipping apply"
else
    echo "Applying KubeletConfig to lower ephemeral-storage eviction thresholds..."
    oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: opp-ephemeral-threshold
spec:
  kubeletConfig:
    evictionHard:
      imagefs.available: "500Mi"
      nodefs.available: "500Mi"
    evictionSoft:
      imagefs.available: "1Gi"
      nodefs.available: "1Gi"
    evictionSoftGracePeriod:
      imagefs.available: "1m"
      nodefs.available: "1m"
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
EOF
    echo "KubeletConfig applied successfully"
fi

# -----------------------------------------------------------------------
# Wait for the worker MCP to finish updating
# -----------------------------------------------------------------------
echo ""
echo "Waiting up to ${MCP_TIMEOUT}s for worker MCP to finish updating..."

# Give the MCO a moment to render the new MachineConfig
sleep 30

# Wait for the MCP to pick up the change (Updating=True, then back to Updated=True)
if oc wait machineconfigpool worker \
    --for=condition=Updated=True \
    --timeout="${MCP_TIMEOUT}s" 2>&1; then
    echo "Worker MCP rollout complete"
else
    echo "WARNING: Worker MCP did not reach Updated=True within ${MCP_TIMEOUT}s"
    echo "Current MCP state:"
    oc get mcp -o wide 2>/dev/null || true
    # Do not fail the step -- downstream wait-mcp will catch lingering issues
fi

echo ""
echo "Final MCP state:"
oc get mcp -o wide 2>/dev/null || true
echo "=== Kubelet config tuning complete ==="
