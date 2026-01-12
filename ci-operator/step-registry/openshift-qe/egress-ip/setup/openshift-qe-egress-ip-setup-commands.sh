#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Setting up egress IP configuration using e2e methodology"

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
    # Use a simple approach: try to get the subnet and assign an IP from it
    # If annotation exists, parse it; otherwise use a default approach
    egress_config=$(oc get node "$WORKER_NODE" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" 2>/dev/null || echo "")
    
    if [[ -n "$egress_config" && "$egress_config" != "null" ]]; then
        # Parse the JSON manually to extract ipv4 CIDR
        # Look for "ipv4":"x.x.x.x/xx" pattern
        egress_cidrs=$(echo "$egress_config" | sed -n 's/.*"ipv4":"\([^"]*\)".*/\1/p' | head -n1)
        if [[ -n "$egress_cidrs" ]]; then
            ip_part=$(echo "$egress_cidrs" | cut -d'/' -f1)
            egress_ip="${ip_part%.*}.10"  # Use .10 instead of .5 to avoid conflicts
        else
            # Fallback: extract node IP and use same subnet
            node_ip=$(oc get node "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
            egress_ip="${node_ip%.*}.10"
            egress_cidrs="${node_ip}/24"
        fi
    else
        # Fallback: extract node IP and use same subnet
        node_ip=$(oc get node "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        egress_ip="${node_ip%.*}.10"
        egress_cidrs="${node_ip}/24"
    fi
    
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
    
    # Create health check URL for krkn chaos testing
    # This allows chaos scripts to monitor the actual egress IP during disruption
    echo "http://ipecho.ipecho-validation.svc.cluster.local" > "$SHARED_DIR/egress-health-check-url"
    echo "Created egress IP health check URL for chaos monitoring: http://ipecho.ipecho-validation.svc.cluster.local"
    
elif [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
    echo "OpenShiftSDN configuration not implemented in this version"
    echo "This test focuses on OVNKubernetes clusters"
    exit 1
else
    echo "Unsupported CNI type: $RUNNING_CNI"
    exit 1
fi

echo "Egress IP setup completed successfully"
