#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Target Discovery
# Discovers egress IP assignments and prepares targeted chaos testing

echo "Starting Egress IP Target Discovery for Chaos Testing"
echo "=================================================="

# Configuration
EIP_NAME="${EIP_NAME:-egress-ip-test}"
NAMESPACE="openshift-ovn-kubernetes"

# Artifact directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Target discovery output file
TARGET_FILE="$ARTIFACT_DIR/egress_ip_targets.env"

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

# Validate prerequisites
log_info "Validating prerequisites..."

# Check cluster connectivity
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster. Please check your kubeconfig."
fi

# Check if egress IP exists
if ! oc get egressip "$EIP_NAME" &> /dev/null; then
    error_exit "Egress IP '$EIP_NAME' not found. Please run setup first."
fi

log_success "Prerequisites validated"

# Discover egress IP assignments
log_info "Discovering egress IP assignments..."

# Get all egress IPs and their assigned nodes
mapfile -t egress_assignments < <(oc get egressip -o json | jq -r '.items[] | "\(.metadata.name):\(.status.items[0].node // "unassigned"):\(.spec.egressIPs[0] // "unknown")"' 2>/dev/null)

if [[ ${#egress_assignments[@]} -eq 0 ]]; then
    error_exit "No egress IP assignments found"
fi

log_info "Found ${#egress_assignments[@]} egress IP assignment(s):"
for assignment in "${egress_assignments[@]}"; do
    IFS=':' read -r eip_name assigned_node egress_ip <<< "$assignment"
    log_info "  - $eip_name -> $assigned_node ($egress_ip)"
done

# Focus on our specific egress IP
ASSIGNED_NODE=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
EGRESS_IP=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")

if [[ -z "$ASSIGNED_NODE" ]]; then
    error_exit "Egress IP $EIP_NAME is not assigned to any node"
fi

log_success "Target egress IP $EIP_NAME assigned to: $ASSIGNED_NODE ($EGRESS_IP)"

# Discover related infrastructure
log_info "Discovering related infrastructure for targeted chaos testing..."

# Find OVN pod on the egress IP node
OVN_POD_ON_EGRESS_NODE=$(oc get pods -n "$NAMESPACE" -o wide | grep "$ASSIGNED_NODE" | awk '/ovnkube-node/{print $1}' | head -1)
if [[ -z "$OVN_POD_ON_EGRESS_NODE" ]]; then
    error_exit "No ovnkube-node pod found on egress IP assigned node $ASSIGNED_NODE"
fi

log_info "Found OVN pod on egress node: $OVN_POD_ON_EGRESS_NODE"

# Get all eligible egress nodes (nodes with egress-assignable label)
mapfile -t EGRESS_ELIGIBLE_NODES < <(oc get nodes -l "k8s.ovn.org/egress-assignable" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)

if [[ ${#EGRESS_ELIGIBLE_NODES[@]} -eq 0 ]]; then
    log_warning "No nodes found with egress-assignable label, falling back to worker nodes"
    mapfile -t EGRESS_ELIGIBLE_NODES < <(oc get nodes -l "node-role.kubernetes.io/worker" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
fi

log_info "Found ${#EGRESS_ELIGIBLE_NODES[@]} egress-eligible node(s): ${EGRESS_ELIGIBLE_NODES[*]}"

# Find all OVN pods on egress-eligible nodes
mapfile -t OVN_PODS_ON_EGRESS_NODES < <(
    for node in "${EGRESS_ELIGIBLE_NODES[@]}"; do
        oc get pods -n "$NAMESPACE" -o wide | grep "$node" | awk '/ovnkube-node/{print $1}'
    done
)

log_info "Found ${#OVN_PODS_ON_EGRESS_NODES[@]} OVN pod(s) on egress-eligible nodes: ${OVN_PODS_ON_EGRESS_NODES[*]}"

# Generate chaos testing configuration
log_info "Generating targeted chaos testing configuration..."

# Write target configuration file
cat > "$TARGET_FILE" << EOF
# Egress IP Target Discovery Results
# Generated on $(date)

# Primary egress IP assignment
export EGRESS_IP_NAME="$EIP_NAME"
export EGRESS_IP_ADDRESS="$EGRESS_IP"
export EGRESS_IP_ASSIGNED_NODE="$ASSIGNED_NODE"
export OVN_POD_ON_EGRESS_NODE="$OVN_POD_ON_EGRESS_NODE"

# All egress-eligible infrastructure
export EGRESS_ELIGIBLE_NODES="${EGRESS_ELIGIBLE_NODES[*]}"
export OVN_PODS_ON_EGRESS_NODES="${OVN_PODS_ON_EGRESS_NODES[*]}"

# Targeted chaos configuration for pod disruption
export TARGET_NAMESPACE="$NAMESPACE"
export TARGET_POD_LABEL="app=ovnkube-node"
export TARGET_NODE_NAMES="$ASSIGNED_NODE"  # Focus on egress IP node
export TARGETED_DISRUPTION_COUNT="1"       # Target specific pod, not all

# Targeted chaos configuration for node disruption  
export TARGET_NODE_LABEL_SELECTOR=""       # Don't use generic label
export TARGET_SPECIFIC_NODE="$ASSIGNED_NODE"  # Target egress IP node specifically
export NODE_DISRUPTION_INSTANCE_COUNT="1"  # Target single node

# Validation configuration
export EXPECTED_EGRESS_RECOVERY_NODE="$ASSIGNED_NODE"  # May change after disruption
export VALIDATE_EGRESS_IP_MIGRATION="true"
EOF

# Display targeting strategy
log_info "Targeted chaos testing strategy:"
log_info "================================"
log_info "🎯 Pod Disruption Target:"
log_info "   - Node: $ASSIGNED_NODE"
log_info "   - Pod: $OVN_POD_ON_EGRESS_NODE" 
log_info "   - Strategy: Target OVN pod on egress IP assigned node"
log_info ""
log_info "🎯 Node Disruption Target:"
log_info "   - Node: $ASSIGNED_NODE"
log_info "   - Strategy: Reboot node currently hosting egress IP"
log_info ""
log_info "🎯 Expected Outcome:"
log_info "   - Egress IP should migrate to another eligible node"
log_info "   - Alternative nodes: ${EGRESS_ELIGIBLE_NODES[*]}"

# Create summary JSON for programmatic consumption
cat > "$ARTIFACT_DIR/egress_ip_targets.json" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "egress_ip": {
    "name": "$EIP_NAME",
    "address": "$EGRESS_IP",
    "assigned_node": "$ASSIGNED_NODE"
  },
  "target_infrastructure": {
    "ovn_pod_on_egress_node": "$OVN_POD_ON_EGRESS_NODE",
    "egress_eligible_nodes": [$(printf '"%s",' "${EGRESS_ELIGIBLE_NODES[@]}" | sed 's/,$//')]
  },
  "chaos_targets": {
    "pod_disruption": {
      "target_node": "$ASSIGNED_NODE",
      "target_pod": "$OVN_POD_ON_EGRESS_NODE",
      "namespace": "$NAMESPACE"
    },
    "node_disruption": {
      "target_node": "$ASSIGNED_NODE",
      "eligible_migration_nodes": [$(printf '"%s",' "${EGRESS_ELIGIBLE_NODES[@]}" | sed 's/,$//'))]
    }
  }
}
EOF

log_success "Target discovery completed successfully!"
log_info "Configuration saved to: $TARGET_FILE"
log_info "JSON summary saved to: $ARTIFACT_DIR/egress_ip_targets.json"

echo "=================================================="
echo "✅ Egress IP target discovery completed"
echo "🎯 Ready for targeted chaos testing"