#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Cleaning up egress IP test resources"

# Load test configuration if available
if [[ -f "$SHARED_DIR/egress-namespace" ]]; then
    TEST_NAMESPACE=$(cat "$SHARED_DIR/egress-namespace")
else
    TEST_NAMESPACE="egress-ip-test"
fi

if [[ -f "$SHARED_DIR/egress-node" ]]; then
    EGRESS_NODE=$(cat "$SHARED_DIR/egress-node")
fi

echo "Cleaning up test namespace: $TEST_NAMESPACE"

# Set error handling to continue on failures during cleanup
set +e

# Delete EgressIP custom resource
echo "Removing EgressIP custom resource..."
oc delete egressip egress-ip-test --ignore-not-found=true

# Delete test namespace
echo "Removing test namespace..."
oc delete namespace "$TEST_NAMESPACE" --ignore-not-found=true

# Remove egress assignable label from node
if [[ -n "${EGRESS_NODE:-}" ]]; then
    echo "Removing egress-assignable label from node: $EGRESS_NODE"
    oc label node "$EGRESS_NODE" k8s.ovn.org/egress-assignable- --ignore-not-found=true
fi

# Clean up any leftover validation resources
echo "Cleaning up validation resources..."
oc delete namespace regular-test --ignore-not-found=true

# Clean up shared directory files
echo "Removing shared configuration files..."
rm -f "$SHARED_DIR/egress-ip" "$SHARED_DIR/egress-node" "$SHARED_DIR/egress-namespace"

echo "Egress IP cleanup completed"