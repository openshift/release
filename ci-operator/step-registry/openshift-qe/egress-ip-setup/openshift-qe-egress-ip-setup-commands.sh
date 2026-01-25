#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Setting up egress IP configuration using Huiran's proven methodology"

# Detect the CNI type
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')
echo "Detected CNI: $RUNNING_CNI"

# Get a worker node for egress IP assignment
WORKER_NODE=$(oc get nodes --selector="node-role.kubernetes.io/worker" -o jsonpath='{.items[0].metadata.name}')
echo "Selected worker node: $WORKER_NODE"

# Create test namespace
TEST_NAMESPACE=${TEST_NAMESPACE:-"egress-ip-test"}
echo "Creating test namespace: $TEST_NAMESPACE"
oc create namespace "$TEST_NAMESPACE" || true

if [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
    echo "Configuring OVNKubernetes egress IP"
    
    # Label the node as egress assignable
    oc label node --overwrite "$WORKER_NODE" k8s.ovn.org/egress-assignable=
    
    # Extract egress IP range from node annotations
    egress_cidrs=$(oc get node "$WORKER_NODE" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" | jq -r '.[].ifaddr.ipv4')
    ip_part=$(echo "$egress_cidrs" | cut -d'/' -f1)
    egress_ip="${ip_part%.*}.10"  # Use .10 instead of .5 to avoid conflicts
    
    echo "Egress IP CIDR: $egress_cidrs"
    echo "Assigned egress IP: $egress_ip"
    
    # Create EgressIP custom resource
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egress-ip-test
spec:
  egressIPs:
  - "${egress_ip}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: "${TEST_NAMESPACE}"
EOF

    # Wait for EgressIP to be assigned
    echo "Waiting for EgressIP assignment..."
    for i in {1..60}; do
        status=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
        if [[ -n "$status" ]]; then
            echo "EgressIP successfully assigned to node: $status"
            break
        fi
        echo "Waiting for EgressIP assignment... (attempt $i/60)"
        sleep 5
    done
    
    # Verify assignment
    assigned_node=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
    if [[ -z "$assigned_node" ]]; then
        echo "ERROR: EgressIP failed to assign to any node"
        oc get egressip egress-ip-test -o yaml
        exit 1
    fi
    
    echo "EgressIP configuration completed successfully"
    echo "Egress IP: $egress_ip assigned to node: $assigned_node"
    
    # Save configuration for validation steps
    echo "$egress_ip" > "$SHARED_DIR/egress-ip"
    echo "$assigned_node" > "$SHARED_DIR/egress-node"
    echo "$TEST_NAMESPACE" > "$SHARED_DIR/egress-namespace"
    
elif [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
    echo "OpenShiftSDN configuration not implemented in this version"
    echo "This test focuses on OVNKubernetes clusters"
    exit 1
else
    echo "Unsupported CNI type: $RUNNING_CNI"
    exit 1
fi

echo "Egress IP setup completed successfully"