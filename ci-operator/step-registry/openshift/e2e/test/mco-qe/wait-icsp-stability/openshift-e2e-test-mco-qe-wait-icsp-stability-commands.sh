#!/bin/bash

set -euo pipefail

echo "=========================================="
echo "Waiting for ICSP-induced cluster stability before Node Disruption Policy tests"
echo "=========================================="

# Set up kubeconfig
if [ -f "${SHARED_DIR}/kubeconfig" ]; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Set up proxy if needed
if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
    echo "Setting up proxy configuration..."
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo ""
echo "Step 1: Check current MachineConfigPool status"
echo "-----------------------------------------------"
oc get mcp -o wide

echo ""
echo "Step 2: Check for any ICSP or IDMS resources"
echo "-----------------------------------------------"
echo "ImageContentSourcePolicy resources:"
oc get imagecontentsourcepolicy -o name 2>/dev/null || echo "  No ICSP found (cluster may be using IDMS)"
echo ""
echo "ImageDigestMirrorSet resources:"
oc get imagedigestmirrorset -o name 2>/dev/null || echo "  No IDMS found (cluster may be using ICSP)"

echo ""
echo "Step 3: Wait for all MachineConfigPools to be stable"
echo "-----------------------------------------------"
echo "Waiting for all MCPs to have:"
echo "  - Updated=True"
echo "  - Updating=False"
echo "  - Degraded=False"
echo "Timeout: 30 minutes"
echo ""

if ! oc wait mcp --all \
  --for=condition=Updated=True \
  --for=condition=Updating=False \
  --for=condition=Degraded=False \
  --timeout=30m; then
    echo "ERROR: MCPs did not stabilize within 30 minutes"
    echo "Current MCP status:"
    oc get mcp -o wide
    echo ""
    echo "Degraded MCPs details:"
    oc get mcp -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name' | while read mcp; do
        echo "=== MCP: $mcp ==="
        oc describe mcp "$mcp"
    done
    exit 1
fi

echo ""
echo "Step 4: Additional stabilization wait"
echo "-----------------------------------------------"
echo "Waiting additional 3 minutes for cluster to fully stabilize..."
echo "This ensures all node reboots from registries.conf changes are complete."
sleep 180

echo ""
echo "Step 5: Verify all nodes are Ready"
echo "-----------------------------------------------"
oc get nodes -o wide

if ! oc wait nodes --all --for=condition=Ready --timeout=5m; then
    echo "ERROR: Not all nodes are Ready"
    oc get nodes -o wide
    exit 1
fi

echo ""
echo "Step 6: Final cluster health verification"
echo "-----------------------------------------------"
echo "Cluster Operators:"
oc get co | grep -E "NAME|False.*True|True.*False.*False"

echo ""
echo "MachineConfigPools (Final state):"
oc get mcp -o wide

echo ""
echo "=========================================="
echo "✓ Cluster is stable and ready for Node Disruption Policy tests"
echo "=========================================="
