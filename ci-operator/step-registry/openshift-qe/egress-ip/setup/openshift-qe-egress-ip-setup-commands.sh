#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Setup with Load Testing
# Sets up egress IP infrastructure and validates configuration

echo "Starting OpenShift QE Egress IP Setup with Load Testing"
echo "========================================================="

# Configuration
PROJECT_COUNT="${PROJECT_COUNT:-4}"
ENABLE_LOAD_TEST="${ENABLE_LOAD_TEST:-true}"
IPECHO_SERVICE_PORT="${IPECHO_SERVICE_PORT:-9095}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

log_info "Configuration:"
log_info "  - Project Count: $PROJECT_COUNT"
log_info "  - Load Testing: $ENABLE_LOAD_TEST"
log_info "  - IPecho Service Port: $IPECHO_SERVICE_PORT"

# Cleanup function for load testing resources
cleanup_load_test_resources() {
    if [[ "$ENABLE_LOAD_TEST" == "true" ]]; then
        log_info "Cleaning up load testing resources..."
        
        # Clean up test namespaces
        for ((i=1; i<=PROJECT_COUNT; i++)); do
            oc delete namespace "egressip-test$i" --ignore-not-found=true --timeout=30s 2>/dev/null || true
        done
        
        # Clean up additional egress IPs
        oc delete egressip egressip-blue egressip-red --ignore-not-found=true 2>/dev/null || true
        
        log_info "Load testing cleanup completed"
    fi
}

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

# Multi-project load testing setup
if [[ "$ENABLE_LOAD_TEST" == "true" ]]; then
    log_info "==============================="
    log_info "LOAD TESTING SETUP"
    log_info "==============================="
    log_info "Setting up $PROJECT_COUNT test projects with blue/red team egress IPs..."
    
    # Calculate additional egress IPs for blue and red teams
    BLUE_EGRESS_IP="${SUBNET_BASE}.251"
    RED_EGRESS_IP="${SUBNET_BASE}.252"
    
    log_info "Blue team egress IP: $BLUE_EGRESS_IP"
    log_info "Red team egress IP: $RED_EGRESS_IP"
    
    # Create blue team egress IP
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-blue
spec:
  egressIPs:
  - "$BLUE_EGRESS_IP"
  namespaceSelector:
    matchLabels:
      egress: egressip1
  podSelector:
    matchLabels:
      team: blue
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF

    # Create red team egress IP
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-red
spec:
  egressIPs:
  - "$RED_EGRESS_IP"
  namespaceSelector:
    matchLabels:
      egress: egressip1
  podSelector:
    matchLabels:
      team: red
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF

    # Wait for blue team egress IP assignment
    log_info "Waiting for blue team egress IP assignment..."
    for i in {1..60}; do
        BLUE_ASSIGNED_NODE=$(oc get egressip egressip-blue -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        if [[ -n "$BLUE_ASSIGNED_NODE" ]]; then
            log_success "Blue team egress IP assigned to node: $BLUE_ASSIGNED_NODE"
            break
        fi
        echo "Waiting for blue team egress IP assignment... ($i/60)"
        sleep 5
    done
    
    # Wait for red team egress IP assignment
    log_info "Waiting for red team egress IP assignment..."
    for i in {1..60}; do
        RED_ASSIGNED_NODE=$(oc get egressip egressip-red -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        if [[ -n "$RED_ASSIGNED_NODE" ]]; then
            log_success "Red team egress IP assigned to node: $RED_ASSIGNED_NODE"
            break
        fi
        echo "Waiting for red team egress IP assignment... ($i/60)"
        sleep 5
    done

    # Create test namespaces
    log_info "Creating $PROJECT_COUNT test namespaces..."
    for ((i=1; i<=PROJECT_COUNT; i++)); do
        NAMESPACE="egressip-test$i"
        
        # Create namespace with egress labels
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    egress: egressip1
EOF
        log_info "Created namespace: $NAMESPACE"
        
        # Create test pods using Deployment (preferred over RC)
        cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-deployment
  namespace: $NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-pod
  template:
    metadata:
      labels:
        app: test-pod
    spec:
      containers:
      - name: test-container
        image: quay.io/openshift/origin-cli:latest
        command: ["sleep", "3600"]
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop:
            - ALL
EOF
        
        # Wait for deployment to be ready
        log_info "Waiting for deployment in $NAMESPACE to be ready..."
        if ! oc wait --for=condition=Available deployment/test-deployment -n "$NAMESPACE" --timeout=300s; then
            log_warning "Deployment in $NAMESPACE may not be ready"
        fi
        
        # Wait for pods to be ready
        log_info "Waiting for pods in $NAMESPACE to be ready..."
        if ! oc wait --for=condition=Ready pod -l app=test-pod -n "$NAMESPACE" --timeout=120s; then
            log_warning "Some pods in $NAMESPACE may not be ready"
        fi
    done

    # Label pods for blue/red teams (wait for pods to be available first)
    log_info "Assigning blue/red team labels to pods..."
    blue_projects=$((PROJECT_COUNT / 2))
    
    for ((i=1; i<=blue_projects; i++)); do
        NAMESPACE="egressip-test$i"
        log_info "Labeling pods in $NAMESPACE as blue team"
        # Ensure pods exist before labeling
        for attempt in {1..30}; do
            if oc get pods -l app=test-pod -n "$NAMESPACE" --no-headers | grep -q "Running\|Ready"; then
                oc label pods -l app=test-pod -n "$NAMESPACE" team=blue --overwrite
                break
            fi
            log_info "Waiting for pods in $NAMESPACE to be available for labeling... (attempt $attempt/30)"
            sleep 2
        done
    done
    
    for ((i=blue_projects+1; i<=PROJECT_COUNT; i++)); do
        NAMESPACE="egressip-test$i"
        log_info "Labeling pods in $NAMESPACE as red team"
        # Ensure pods exist before labeling
        for attempt in {1..30}; do
            if oc get pods -l app=test-pod -n "$NAMESPACE" --no-headers | grep -q "Running\|Ready"; then
                oc label pods -l app=test-pod -n "$NAMESPACE" team=red --overwrite
                break
            fi
            log_info "Waiting for pods in $NAMESPACE to be available for labeling... (attempt $attempt/30)"
            sleep 2
        done
    done
    
    log_success "Load testing setup completed with $PROJECT_COUNT projects!"
else
    log_info "Load testing disabled, using single egress IP configuration"
fi

# Display final status
echo ""
echo "======================================="
echo "Egress IP Setup Summary"
echo "======================================="
oc get egressip -o wide
echo ""
if [[ "$ENABLE_LOAD_TEST" == "true" ]]; then
    echo "Test namespaces:"
    oc get namespaces -l egress=egressip1 --no-headers | wc -l
    echo ""
fi
echo "✅ Egress IP infrastructure setup completed successfully!"
