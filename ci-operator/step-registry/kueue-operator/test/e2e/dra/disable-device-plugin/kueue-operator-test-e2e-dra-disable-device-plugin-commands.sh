#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Disabling NVIDIA device plugin"
echo "========================================="
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Patching ClusterPolicy to disable device plugin..."
oc patch clusterpolicy gpu-cluster-policy --type=merge -p '{"spec":{"devicePlugin":{"enabled":false}}}'

echo "Waiting for ClusterPolicy to be ready..."
oc wait clusterpolicy --all --for=condition=Ready --timeout=10m

echo ""
echo "Device plugin disabled"
echo ""
