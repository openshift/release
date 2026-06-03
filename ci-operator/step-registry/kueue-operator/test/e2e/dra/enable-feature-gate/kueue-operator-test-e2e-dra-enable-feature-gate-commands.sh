#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Enabling DRAExtendedResource feature gate"
echo "========================================="
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Patching featuregates..."
oc patch featuregates cluster --type='merge' -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["DRAExtendedResource"]}}}'

echo "Waiting for kube-apiserver to start rolling out..."
oc wait co kube-apiserver --for='condition=Progressing=True' --timeout=5m || true

echo "Waiting for kube-apiserver rollout to complete..."
oc wait co kube-apiserver --for='condition=Progressing=False' --timeout=30m

echo ""
echo "DRAExtendedResource feature gate enabled"
echo ""
