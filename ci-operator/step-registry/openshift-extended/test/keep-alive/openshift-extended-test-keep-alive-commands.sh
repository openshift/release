#!/bin/bash
set -euo pipefail

echo "=============================================="
echo "  Cluster kept alive for up to 12 hours"
echo "=============================================="
echo ""
echo "Cluster info:"
echo "  API: $(oc whoami --show-server 2>/dev/null || echo 'N/A')"
echo "  Nodes: $(oc get nodes --no-headers 2>/dev/null | wc -l || echo 'N/A')"
echo ""
echo "To destroy cluster early:"
echo "  oc create configmap stop-preserving -n default"
echo ""
echo "=============================================="

timeout 12h bash -c 'while true; do
    if oc get cm/stop-preserving -n default &> /dev/null 2>&1; then
        echo "Stop signal received, exiting..."
        break
    fi
    sleep 30
done' || echo "Timeout reached"

echo "Keep-alive completed"
