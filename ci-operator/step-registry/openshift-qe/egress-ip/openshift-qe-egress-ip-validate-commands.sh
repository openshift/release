#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Validating egress IP configuration using internal routing verification"

# Load saved configuration
if [[ ! -f "$SHARED_DIR/egress-ip" ]] || [[ ! -f "$SHARED_DIR/egress-node" ]] || [[ ! -f "$SHARED_DIR/egress-namespace" ]]; then
    echo "ERROR: Egress IP configuration not found. Setup step may have failed."
    exit 1
fi

EGRESS_IP=$(cat "$SHARED_DIR/egress-ip")
EGRESS_NODE=$(cat "$SHARED_DIR/egress-node")
TEST_NAMESPACE=$(cat "$SHARED_DIR/egress-namespace")

echo "Validating egress IP: $EGRESS_IP on node: $EGRESS_NODE for namespace: $TEST_NAMESPACE"

# Validate EgressIP CR configuration (Huiran's method)
validate_egressip_cr() {
    echo "Validating EgressIP custom resource configuration..."
    
    # Get current EgressIP configuration
    current_config_unformatted=$(oc get egressip egress-ip-test -o json | jq .spec)
    current_config="$(echo -e "${current_config_unformatted}" | tr -d '[:space:]')"
    
    # Get the node where EgressIP is assigned
    egressIP_node=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].node}')
    
    # Extract expected egress CIDR from node annotations
    expected_egressCIDRs=$(oc get node "$egressIP_node" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" | jq -r '.[].ifaddr.ipv4')
    ip_part=$(echo "$expected_egressCIDRs" | cut -d'/' -f1)
    expected_egressIP="${ip_part%.*}.10"  # Match the IP we assigned
    
    # Build expected configuration
    expected_config="{\"egressIPs\":[\"$expected_egressIP\"],\"namespaceSelector\":{\"matchLabels\":{\"kubernetes.io/metadata.name\":\"$TEST_NAMESPACE\"}}}"
    
    echo "Current config: $current_config"
    echo "Expected config: $expected_config"
    
    if diff <(echo "$current_config") <(echo "$expected_config"); then
        echo "✓ EgressIP CR configuration validation PASSED"
        return 0
    else
        echo "✗ EgressIP CR configuration validation FAILED"
        return 1
    fi
}

# Validate EgressIP assignment and status
validate_egressip_assignment() {
    echo "Validating EgressIP assignment status..."
    
    # Check if EgressIP is assigned
    assigned_node=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
    
    if [[ -z "$assigned_node" ]]; then
        echo "✗ EgressIP assignment validation FAILED - no node assigned"
        oc get egressip egress-ip-test -o yaml
        return 1
    fi
    
    echo "✓ EgressIP successfully assigned to node: $assigned_node"
    
    # Verify the assigned IP matches expectation
    assigned_ip=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].egressIP}')
    if [[ "$assigned_ip" == "$EGRESS_IP" ]]; then
        echo "✓ EgressIP assignment validation PASSED - IP: $assigned_ip"
        return 0
    else
        echo "✗ EgressIP assignment validation FAILED - Expected: $EGRESS_IP, Got: $assigned_ip"
        return 1
    fi
}

# Test internal routing behavior
validate_internal_routing() {
    echo "Validating internal routing behavior..."
    
    # Create test pods in both egress-enabled and regular namespaces
    echo "Creating test pods for routing validation..."
    
    # Pod in egress-enabled namespace
    oc run test-egress-pod --image=quay.io/openshifttest/hello-sdn:latest --restart=Never -n "$TEST_NAMESPACE" -- sleep 3600
    
    # Pod in regular namespace for comparison
    oc create namespace regular-test || true
    oc run test-regular-pod --image=quay.io/openshifttest/hello-sdn:latest --restart=Never -n regular-test -- sleep 3600
    
    # Wait for pods to be ready
    echo "Waiting for test pods to be ready..."
    oc wait --for=condition=Ready pod/test-egress-pod -n "$TEST_NAMESPACE" --timeout=120s
    oc wait --for=condition=Ready pod/test-regular-pod -n regular-test --timeout=120s
    
    # Get pod details for verification
    egress_pod_node=$(oc get pod test-egress-pod -n "$TEST_NAMESPACE" -o jsonpath='{.spec.nodeName}')
    regular_pod_node=$(oc get pod test-regular-pod -n regular-test -o jsonpath='{.spec.nodeName}')
    
    echo "Egress pod on node: $egress_pod_node"
    echo "Regular pod on node: $regular_pod_node"
    echo "EgressIP assigned to node: $EGRESS_NODE"
    
    # Test connectivity between pods (internal routing validation)
    echo "Testing internal pod-to-pod connectivity..."
    
    regular_pod_ip=$(oc get pod test-regular-pod -n regular-test -o jsonpath='{.status.podIP}')
    
    # Test connectivity from egress pod to regular pod
    if oc exec test-egress-pod -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 10 "$regular_pod_ip:8080" > /dev/null; then
        echo "✓ Internal routing validation PASSED - egress pod can reach regular pod"
    else
        echo "✗ Internal routing validation FAILED - connectivity issue"
        return 1
    fi
    
    echo "✓ Internal routing behavior validated successfully"
    return 0
}

# Cleanup test resources
cleanup_validation_resources() {
    echo "Cleaning up validation test resources..."
    set +e  # Don't fail on cleanup errors
    oc delete pod test-egress-pod -n "$TEST_NAMESPACE" --ignore-not-found=true
    oc delete pod test-regular-pod -n regular-test --ignore-not-found=true
    oc delete namespace regular-test --ignore-not-found=true
    set -e
}

# Main validation sequence
VALIDATION_ERRORS=0

echo "=== Starting egress IP validation ==="

# Run validation checks
validate_egressip_cr || ((VALIDATION_ERRORS++))
validate_egressip_assignment || ((VALIDATION_ERRORS++))
validate_internal_routing || ((VALIDATION_ERRORS++))

# Cleanup
cleanup_validation_resources

echo "=== Validation completed ==="

if [[ $VALIDATION_ERRORS -eq 0 ]]; then
    echo "✓ All egress IP validations PASSED"
    exit 0
else
    echo "✗ $VALIDATION_ERRORS validation(s) FAILED"
    exit 1
fi