#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Setup
# Sets up egress IP infrastructure and validates configuration

echo "Starting OpenShift QE Egress IP Setup"
echo "======================================="

# Check cluster connectivity
if ! oc cluster-info &> /dev/null; then
    echo "ERROR: Cannot connect to OpenShift cluster. Please check your kubeconfig."
    exit 1
fi

# Get cluster information
MASTER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/master= --no-headers | wc -l)
WORKER_NODES_COUNT=$(oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l)
echo "Cluster has $MASTER_NODES_COUNT master nodes and $WORKER_NODES_COUNT worker nodes"

if [[ $WORKER_NODES_COUNT -lt 2 ]]; then
    echo "ERROR: Need at least 2 worker nodes for egress testing"
    exit 1
fi

# Get worker nodes
worker_node1=$(oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==1{print $1}')
worker_node2=$(oc get node -l node-role.kubernetes.io/worker= --no-headers|awk 'NR==2{print $1}')
echo "Using worker nodes: $worker_node1, $worker_node2"

# Label nodes as egress-assignable
echo "Setting up egress-assignable nodes..."
for node in "$worker_node1" "$worker_node2"; do
    if oc get node "$node" --show-labels | grep -q "egress-assignable"; then
        echo "Node $node already egress-assignable"
    else
        echo "Labeling node $node as egress-assignable"
        oc label node "$node" "k8s.ovn.org/egress-assignable"=""
    fi
done

# Create egress IP configuration if it doesn't exist
echo "Setting up egress IP configurations..."

# Create egressip2 configuration
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip2
spec:
  egressIPs:
  - "10.0.128.5"
  namespaceSelector:
    matchLabels:
      egress: egressip2
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF

# Wait for egress IP assignment
echo "Waiting for egress IP assignment..."
for i in {1..60}; do
    ASSIGNED_NODE=$(oc get egressip egressip2 -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -n "$ASSIGNED_NODE" ]]; then
        echo "✅ Egress IP egressip2 assigned to node: $ASSIGNED_NODE"
        break
    fi
    echo "Waiting for egress IP assignment... ($i/60)"
    sleep 5
done

if [[ -z "$ASSIGNED_NODE" ]]; then
    echo "ERROR: Egress IP was not assigned within timeout"
    exit 1
fi

# Verify node status
NODE_STATUS=$(oc get node "$ASSIGNED_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
echo "Assigned node status: $NODE_STATUS"

# Check OVN pod on assigned node
OVN_POD=$(oc get pods -n openshift-ovn-kubernetes -o wide | grep "$ASSIGNED_NODE" | awk '/ovnkube-node/{print $1}' | head -1)
if [[ -n "$OVN_POD" ]]; then
    echo "✅ OVN Pod on assigned node: $OVN_POD"
    POD_STATUS=$(oc get pod -n openshift-ovn-kubernetes "$OVN_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "Pod Status: $POD_STATUS"
else
    echo "ERROR: No OVN pod found on assigned node"
    exit 1
fi

# Display final status
echo ""
echo "======================================="
echo "Egress IP Setup Summary"
echo "======================================="
oc get egressip -o wide
echo ""
echo "✅ Egress IP infrastructure setup completed successfully!"
