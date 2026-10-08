#!/bin/bash

set -euo pipefail

NS="openshift-operators"

echo "Installing quay-operator bundle: $OO_BUNDLE"
operator-sdk run bundle --timeout=10m --security-context-config restricted \
  -n "$NS" "$OO_BUNDLE"

echo "Waiting for quay-operator deployment..."
oc wait --timeout=10m --for condition=Available -n "$NS" \
  deployment/quay-operator-tng

echo "quay-operator installed successfully"
