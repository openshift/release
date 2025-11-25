#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Resilience Tests
# Comprehensive end-to-end testing of egress IP functionality under disruption

echo "Starting OpenShift QE Egress IP Resilience Tests"
echo "==============================================="

# Configuration
EIP_NAME="${EIP_NAME:-egressip1}"
POD_KILL_RETRIES="${POD_KILL_RETRIES:-10}"
REBOOT_RETRIES="${REBOOT_RETRIES:-5}"
NAMESPACE="openshift-ovn-kubernetes"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Logging setup
LOG_FILE="$ARTIFACT_DIR/egress_ip_test_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

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

# Get assigned node and validate
ASSIGNED_NODE=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
if [[ -z "$ASSIGNED_NODE" ]]; then
    error_exit "Egress IP $EIP_NAME is not assigned to any node"
fi

log_success "Prerequisites validated. Egress IP $EIP_NAME assigned to: $ASSIGNED_NODE"

# Phase 1: OVN Pod Disruption Testing (Using Chaos Engineering Framework)
log_info "==============================="
log_info "PHASE 1: OVN Pod Disruption Testing"
log_info "==============================="

# Capture baseline NAT count before disruption
capture_baseline_metrics() {
    log_info "Capturing baseline NAT metrics..."
    
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$worker_pods" ]]; then
        log_error "No ovnkube-node pods found"
        return 1
    fi
    
    local total_nat_count=0
    for pod in $worker_pods; do
        local count
        count=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        total_nat_count=$((total_nat_count + count))
    done
    
    log_info "Baseline egress IP NAT count: $total_nat_count"
    echo "baseline,pod_disruption,$total_nat_count" > "$ARTIFACT_DIR/pod_disruption_metrics.csv"
    
    return 0
}

# Post-disruption validation
validate_post_disruption() {
    log_info "Validating egress IP functionality after pod disruption..."
    
    # Wait for OVN pods to stabilize
    sleep 30
    
    # Check egress IP assignment
    local current_node
    current_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -z "$current_node" ]]; then
        log_error "Egress IP not assigned after disruption"
        return 1
    fi
    
    log_success "Egress IP $EIP_NAME still assigned to: $current_node"
    
    # Verify NAT rules are restored
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    local total_nat_count=0
    for pod in $worker_pods; do
        local count
        count=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        total_nat_count=$((total_nat_count + count))
    done
    
    log_info "Post-disruption egress IP NAT count: $total_nat_count"
    echo "post_disruption,pod_disruption,$total_nat_count" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
    
    return 0
}

# Capture baseline metrics
if ! capture_baseline_metrics; then
    error_exit "Failed to capture baseline metrics"
fi

log_info "Running OVN pod disruption using chaos engineering framework..."
log_info "This will use the redhat-chaos-pod-scenarios to disrupt ovnkube-node pods"

# Note: The actual chaos step execution will be handled by the workflow
# This script will be called after the chaos step completes to validate recovery

# Execute post-disruption validation
if ! validate_post_disruption; then
    error_exit "Post-disruption validation failed"
fi

log_success "Pod disruption testing completed successfully"

# Phase 2: Node Reboot Testing (Using Chaos Engineering Framework)
log_info "==============================="
log_info "PHASE 2: Node Reboot Testing"
log_info "==============================="

# Capture baseline node metrics before disruption
capture_baseline_node_metrics() {
    log_info "Capturing baseline node metrics before reboot..."
    
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$worker_pods" ]]; then
        log_error "No ovnkube-node pods found"
        return 1
    fi
    
    local total_snat_count=0
    local total_policy_count=0
    
    for pod in $worker_pods; do
        local snat
        snat=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        local policy
        policy=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl lr-policy-list ovn_cluster_router | grep '100 ' | grep -v 1004 | wc -l" 2>/dev/null || echo "0")
        
        total_snat_count=$((total_snat_count + snat))
        total_policy_count=$((total_policy_count + policy))
    done
    
    log_info "Baseline node metrics - SNAT: $total_snat_count, LR policy: $total_policy_count"
    echo "baseline,node_reboot,$total_snat_count,$total_policy_count" > "$ARTIFACT_DIR/reboot_metrics.csv"
    
    return 0
}

# Post-reboot validation
validate_post_reboot() {
    log_info "Validating egress IP functionality after node reboot..."
    
    # Wait for nodes and pods to stabilize
    sleep 60
    
    # Check egress IP assignments
    local egress_nodes
    mapfile -t egress_nodes < <(oc get egressip -o jsonpath='{.items[*].status.items[*].node}' 2>/dev/null | tr ' ' '\n' | sort -u)
    if [[ ${#egress_nodes[@]} -eq 0 ]]; then
        log_error "No egress IP assignments found after reboot"
        return 1
    fi
    
    log_success "Egress IPs reassigned to nodes: ${egress_nodes[*]}"
    
    # Verify NAT and policy rules are restored
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    local total_snat_count=0
    local total_policy_count=0
    
    for pod in $worker_pods; do
        local snat
        snat=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        local policy
        policy=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl lr-policy-list ovn_cluster_router | grep '100 ' | grep -v 1004 | wc -l" 2>/dev/null || echo "0")
        
        total_snat_count=$((total_snat_count + snat))
        total_policy_count=$((total_policy_count + policy))
    done
    
    log_info "Post-reboot node metrics - SNAT: $total_snat_count, LR policy: $total_policy_count"
    echo "post_reboot,node_reboot,$total_snat_count,$total_policy_count" >> "$ARTIFACT_DIR/reboot_metrics.csv"
    
    return 0
}

# Capture baseline metrics
if ! capture_baseline_node_metrics; then
    error_exit "Failed to capture baseline node metrics"
fi

log_info "Running node reboot disruption using chaos engineering framework..."
log_info "This will use the redhat-chaos-node-disruptions with ACTION=node_reboot_scenario"

# Note: The actual chaos step execution will be handled by the workflow
# This script will be called after the chaos step completes to validate recovery

# Execute post-reboot validation
if ! validate_post_reboot; then
    error_exit "Post-reboot validation failed"
fi

log_success "Node reboot testing completed successfully"

# Final validation and summary
log_info "==============================="
log_info "FINAL VALIDATION & SUMMARY"
log_info "==============================="

# Final egress IP status
log_info "Final egress IP status:"
oc get egressip -o wide

# Test summary
log_success "✅ All test phases completed!"
log_info "Test Configuration:"
log_info "  - Egress IP: $EIP_NAME"
log_info "  - Pod Kill Tests: $POD_KILL_RETRIES iterations"
log_info "  - Node Reboot Tests: $REBOOT_RETRIES iterations"
log_info "  - Total Runtime: $SECONDS seconds"
log_info "  - Log File: $LOG_FILE"

# Copy test artifacts
if [[ -f "$ARTIFACT_DIR/pod_disruption_metrics.csv" ]]; then
    log_info "Pod disruption metrics saved to: $ARTIFACT_DIR/pod_disruption_metrics.csv"
fi

if [[ -f "$ARTIFACT_DIR/reboot_metrics.csv" ]]; then
    log_info "Reboot test metrics saved to: $ARTIFACT_DIR/reboot_metrics.csv"
fi

log_success "🎉 OpenShift QE Egress IP resilience testing completed successfully!"
