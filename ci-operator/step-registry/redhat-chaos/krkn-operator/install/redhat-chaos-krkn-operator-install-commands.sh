#!/bin/bash
set -o errexit

set -o nounset
set -o pipefail
set -x


helm install krkn-operator oci://quay.io/krkn-chaos/charts/krkn-operator \
  --version $KRKN_OPERATOR_VERSION \
  --namespace $TARGET_NAMESPACE \
  --create-namespace \
  --set acm.enabled=true

echo "✓ krkn-operator installed"

kubectl get managedclusters

kubectl get all -n $TARGET_NAMESPACE

echo ""
echo "Waiting for krkn-operator deployment to be ready..."
kubectl wait --for=condition=available deployment/krkn-operator-operator \
  -n $TARGET_NAMESPACE \
  --timeout=300s

kubectl wait --for=condition=ready pod \
  -n $TARGET_NAMESPACE \
  -l app.kubernetes.io/component=operator \
  --timeout=120s