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

# Determine the cluster's subnet and get an available IP
echo "Determining cluster subnet..."
CLUSTER_SUBNET=$(oc get network.config/cluster -o jsonpath='{.status.clusterNetwork[0].cidr}')
echo "Cluster network CIDR: $CLUSTER_SUBNET"

# Get the base IP and calculate an available egress IP
# For AWS clusters, we'll use the machine subnet which is typically different from pod CIDR
MACHINE_SUBNET=$(oc get machines -n openshift-machine-api -o jsonpath='{.items[0].spec.providerSpec.value.subnet.id}' 2>/dev/null || echo "")

# If we can't get machine subnet, get node IPs and calculate from there
if [[ -z "$MACHINE_SUBNET" ]]; then
    NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    echo "Using node IP for subnet calculation: $NODE_IP"
    
    # Extract subnet (assumes /24 for AWS) and use .250 as egress IP
    SUBNET_BASE=$(echo "$NODE_IP" | cut -d. -f1-3)
    EGRESS_IP="${SUBNET_BASE}.250"
else
    # For more robust subnet detection, we'll use a default approach
    NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    SUBNET_BASE=$(echo "$NODE_IP" | cut -d. -f1-3)
    EGRESS_IP="${SUBNET_BASE}.250"
fi

echo "Calculated egress IP: $EGRESS_IP"

# Create egressip1 configuration
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip1
spec:
  egressIPs:
  - "$EGRESS_IP"
  namespaceSelector:
    matchLabels:
      egress: egressip1
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF

# Wait for egress IP assignment
echo "Waiting for egress IP assignment..."
for i in {1..60}; do
    ASSIGNED_NODE=$(oc get egressip egressip1 -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -n "$ASSIGNED_NODE" ]]; then
        echo "✅ Egress IP egressip1 assigned to node: $ASSIGNED_NODE"
        break
    fi
    
    # Debug output every 10 iterations
    if [[ $((i % 10)) -eq 0 ]]; then
        echo "Debug: Checking egress IP status..."
        oc get egressip egressip1 -o yaml | head -50 || echo "Failed to get egress IP details"
        echo "Available egress-assignable nodes:"
        oc get nodes -l k8s.ovn.org/egress-assignable= --no-headers | awk '{print $1 " " $2}' || echo "No egress-assignable nodes found"
    fi
    
    echo "Waiting for egress IP assignment... ($i/60)"
    sleep 5
done

if [[ -z "$ASSIGNED_NODE" ]]; then
    echo "ERROR: Egress IP was not assigned within timeout"
    echo "Final egress IP status:"
    oc get egressip egressip1 -o yaml || echo "Failed to get final egress IP status"
    echo "Egress-assignable nodes:"
    oc get nodes -l k8s.ovn.org/egress-assignable= || echo "No egress-assignable nodes"
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
