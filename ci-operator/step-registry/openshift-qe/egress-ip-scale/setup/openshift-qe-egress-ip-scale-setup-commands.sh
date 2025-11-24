#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Scale Test Setup
# Creates 10 EgressIP objects with 200 pods each for SNAT/LRP rule validation

echo "Starting OpenShift QE Egress IP Scale Test Setup"
echo "================================================"

# Configuration
EIP_COUNT="${EIP_COUNT:-10}"
PODS_PER_EIP="${PODS_PER_EIP:-200}"
TOTAL_PODS=$((EIP_COUNT * PODS_PER_EIP))
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-scale-eip}"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

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

error_exit() {
    log_error "$*"
    exit 1
}

log_info "Scale Test Configuration:"
log_info "  - EgressIP objects: $EIP_COUNT"
log_info "  - Pods per EgressIP: $PODS_PER_EIP"
log_info "  - Total pods: $TOTAL_PODS"
log_info "  - Expected SNAT rules: $TOTAL_PODS"
log_info "  - Expected LRP rules: $TOTAL_PODS"

# Check cluster connectivity
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster. Please check your kubeconfig."
fi

# Get worker nodes and label them as egress-assignable
log_info "Labeling worker nodes as egress-assignable..."
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker= --no-headers -o custom-columns=":metadata.name")
if [[ -z "$WORKER_NODES" ]]; then
    error_exit "No worker nodes found in cluster"
fi

# Label all worker nodes as egress-assignable
for node in $WORKER_NODES; do
    log_info "Labeling node $node as egress-assignable"
    oc label node "$node" k8s.ovn.org/egress-assignable="" --overwrite
done

# Get the first worker node's subnet for IP calculation
FIRST_NODE=$(echo "$WORKER_NODES" | head -1)
NODE_IP=$(oc get node "$FIRST_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
SUBNET_BASE=$(echo "$NODE_IP" | cut -d'.' -f1-3)

log_info "Using subnet base: $SUBNET_BASE for egress IP allocation"

# Cleanup function
cleanup_scale_test() {
    log_info "Cleaning up scale test resources..."
    
    # Clean up namespaces
    for ((i=1; i<=EIP_COUNT; i++)); do
        oc delete namespace "${NAMESPACE_PREFIX}$i" --ignore-not-found=true --timeout=60s &
    done
    wait
    
    # Clean up egress IPs
    for ((i=1; i<=EIP_COUNT; i++)); do
        oc delete egressip "eip-scale-$i" --ignore-not-found=true &
    done
    wait
    
    log_info "Scale test cleanup completed"
}

# Create scale test configuration file
cat > "$ARTIFACT_DIR/scale_test_config.yaml" << EOF
scale_test_config:
  eip_count: $EIP_COUNT
  pods_per_eip: $PODS_PER_EIP
  total_pods: $TOTAL_PODS
  namespace_prefix: $NAMESPACE_PREFIX
  subnet_base: $SUBNET_BASE
  expected_snat_rules: $TOTAL_PODS
  expected_lrp_rules: $TOTAL_PODS
EOF

log_info "==============================="
log_info "Creating $EIP_COUNT EgressIP Objects"
log_info "==============================="

# Create EgressIP objects
for ((i=1; i<=EIP_COUNT; i++)); do
    EIP_NAME="eip-scale-$i"
    EGRESS_IP="${SUBNET_BASE}.$((100 + i))"  # Use .101, .102, .103, etc.
    
    log_info "Creating EgressIP $EIP_NAME with IP $EGRESS_IP"
    
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: $EIP_NAME
spec:
  egressIPs:
  - "$EGRESS_IP"
  namespaceSelector:
    matchLabels:
      eip-group: "scale-group-$i"
  podSelector:
    matchLabels:
      app: scale-test-pod
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF
done

log_info "==============================="
log_info "Creating $EIP_COUNT Namespaces with $PODS_PER_EIP pods each"
log_info "==============================="

# Create namespaces and pods
for ((i=1; i<=EIP_COUNT; i++)); do
    NAMESPACE="${NAMESPACE_PREFIX}$i"
    EIP_GROUP="scale-group-$i"
    
    log_info "Creating namespace $NAMESPACE with $PODS_PER_EIP pods"
    
    # Create namespace
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    eip-group: "$EIP_GROUP"
    scale-test: "true"
EOF
    
    # Calculate number of deployments needed (10 pods per deployment = 20 deployments for 200 pods)
    PODS_PER_DEPLOYMENT=10
    DEPLOYMENT_COUNT=$((PODS_PER_EIP / PODS_PER_DEPLOYMENT))
    
    log_info "Creating $DEPLOYMENT_COUNT deployments in $NAMESPACE ($PODS_PER_DEPLOYMENT pods each)"
    
    # Create deployments to generate the required number of pods
    for ((j=1; j<=DEPLOYMENT_COUNT; j++)); do
        DEPLOYMENT_NAME="scale-test-deploy-$j"
        
        cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_NAME
  namespace: $NAMESPACE
spec:
  replicas: $PODS_PER_DEPLOYMENT
  selector:
    matchLabels:
      app: scale-test-pod
      deployment: "$DEPLOYMENT_NAME"
  template:
    metadata:
      labels:
        app: scale-test-pod
        deployment: "$DEPLOYMENT_NAME"
        eip-group: "$EIP_GROUP"
    spec:
      containers:
      - name: test-container
        image: quay.io/openshift/origin-cli:latest
        command: ["sleep", "7200"]
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop:
            - ALL
EOF
    done &  # Background the deployment creation for this namespace
done

# Wait for all namespace deployments to be created
wait

log_info "Waiting for all EgressIP assignments..."

# Wait for all EgressIPs to be assigned
for ((i=1; i<=EIP_COUNT; i++)); do
    EIP_NAME="eip-scale-$i"
    log_info "Waiting for EgressIP $EIP_NAME assignment..."
    
    for attempt in {1..120}; do
        ASSIGNED_NODE=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        if [[ -n "$ASSIGNED_NODE" ]]; then
            log_success "EgressIP $EIP_NAME assigned to node: $ASSIGNED_NODE"
            echo "$EIP_NAME,$ASSIGNED_NODE,${SUBNET_BASE}.$((100 + i))" >> "$ARTIFACT_DIR/eip_assignments.csv"
            break
        fi
        
        if [[ $((attempt % 10)) -eq 0 ]]; then
            log_info "Still waiting for $EIP_NAME assignment... (attempt $attempt/120)"
        fi
        sleep 5
    done
    
    if [[ -z "$ASSIGNED_NODE" ]]; then
        log_error "EgressIP $EIP_NAME failed to get assigned within timeout"
    fi
done

log_info "Waiting for all pods to be ready..."

# Wait for pods to be ready in all namespaces
for ((i=1; i<=EIP_COUNT; i++)); do
    NAMESPACE="${NAMESPACE_PREFIX}$i"
    
    log_info "Waiting for pods in $NAMESPACE to be ready..."
    
    # Wait for deployments to be available
    if ! oc wait --for=condition=Available deployment --all -n "$NAMESPACE" --timeout=600s; then
        log_warning "Some deployments in $NAMESPACE may not be ready"
    fi
    
    # Count ready pods
    READY_PODS=$(oc get pods -n "$NAMESPACE" -l app=scale-test-pod --field-selector=status.phase=Running --no-headers | wc -l)
    log_info "Namespace $NAMESPACE: $READY_PODS/$PODS_PER_EIP pods ready"
done

# Generate final summary
log_info "==============================="
log_info "Scale Test Setup Summary"
log_info "==============================="

# Count total ready pods
TOTAL_READY_PODS=0
for ((i=1; i<=EIP_COUNT; i++)); do
    NAMESPACE="${NAMESPACE_PREFIX}$i"
    NAMESPACE_READY_PODS=$(oc get pods -n "$NAMESPACE" -l app=scale-test-pod --field-selector=status.phase=Running --no-headers | wc -l)
    TOTAL_READY_PODS=$((TOTAL_READY_PODS + NAMESPACE_READY_PODS))
    echo "  - $NAMESPACE: $NAMESPACE_READY_PODS/$PODS_PER_EIP pods"
done

log_info "Total Ready Pods: $TOTAL_READY_PODS/$TOTAL_PODS"

# Show EgressIP status
echo ""
log_info "EgressIP Status:"
oc get egressip -l 'metadata.name ~ eip-scale-.*' -o wide

# Save summary to artifact
cat > "$ARTIFACT_DIR/scale_setup_summary.txt" << EOF
Scale Test Setup Summary
========================
EgressIP Count: $EIP_COUNT
Pods per EgressIP: $PODS_PER_EIP
Total Pods Created: $TOTAL_PODS
Total Ready Pods: $TOTAL_READY_PODS
Expected SNAT Rules: $TOTAL_PODS
Expected LRP Rules: $TOTAL_PODS

Setup completed at: $(date)
EOF

if [[ $TOTAL_READY_PODS -eq $TOTAL_PODS ]]; then
    log_success "✅ Scale test setup completed successfully!"
    log_success "Ready for SNAT/LRP rule validation and failover testing"
else
    log_warning "⚠️ Scale test setup completed with some pods not ready ($TOTAL_READY_PODS/$TOTAL_PODS)"
fi

log_info "Scale test configuration saved to: $ARTIFACT_DIR/"