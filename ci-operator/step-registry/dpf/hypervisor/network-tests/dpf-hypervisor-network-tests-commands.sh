#!/bin/bash
set -euo pipefail

echo "=== Run DPF Kubernetes Traffic Flow Tests ==="

echo "Verifying cluster access..."
oc get nodes

export TFT_SERVER_NODE=$(oc get nodes --no-headers | grep worker-dpu | awk 'NR==1 {print $1}')
echo "TFT_SERVER_NODE: ${TFT_SERVER_NODE}"
export TFT_CLIENT_NODE=$(oc get nodes --no-headers | grep worker-dpu | awk 'NR==2 {print $1}')
echo "TFT_CLIENT_NODE: ${TFT_CLIENT_NODE}"

make run-traffic-flow-tests
