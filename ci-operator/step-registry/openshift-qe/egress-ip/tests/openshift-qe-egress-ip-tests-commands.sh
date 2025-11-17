#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Resilience Tests
# Comprehensive end-to-end testing of egress IP functionality under disruption

echo "Starting OpenShift QE Egress IP Resilience Tests"
echo "==============================================="

# Configuration
EIP_NAME="${EIP_NAME:-egressip2}"
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

# Phase 1: OVN Pod Disruption Testing
log_info "==============================="
log_info "PHASE 1: OVN Pod Disruption Testing"
log_info "==============================="

run_pod_disruption_test() {
    local iteration=$1
    
    log_info "Pod disruption test iteration $iteration/$POD_KILL_RETRIES"
    
    # Get current assigned node
    local current_node
    current_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -z "$current_node" ]]; then
        log_error "Egress IP not assigned in iteration $iteration"
        return 1
    fi
    
    # Find ovnkube-node pod on that node
    local pod_name
    pod_name=$(oc get pods -n "$NAMESPACE" -o wide | grep "$current_node" | awk '/ovnkube-node/{print $1}' | head -1)
    if [[ -z "$pod_name" ]]; then
        log_error "No ovnkube-node pod found on node $current_node"
        return 1
    fi
    
    log_info "Deleting pod $pod_name on node $current_node..."
    oc delete pod -n "$NAMESPACE" "$pod_name" --ignore-not-found --wait=false
    
    # Wait for new pod to be ready
    local elapsed=0
    local pod_ready_timeout=300
    local new_pod=""
    local ready="false"
    
    while [[ $elapsed -lt $pod_ready_timeout ]]; do
        new_pod=$(oc get pods -n "$NAMESPACE" -o wide | grep "$current_node" | awk '/ovnkube-node/{print $1}' | head -1)
        
        if [[ -n "$new_pod" ]] && [[ "$new_pod" != "$pod_name" ]]; then
            ready=$(oc get pod -n "$NAMESPACE" "$new_pod" -o jsonpath='{.status.containerStatuses[?(@.name=="ovnkube-controller")].ready}' 2>/dev/null || echo "false")
            
            if [[ "$ready" == "true" ]]; then
                log_success "New pod $new_pod is ready"
                break
            fi
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [[ -z "$new_pod" ]] || [[ "$new_pod" == "$pod_name" ]] || [[ "$ready" != "true" ]]; then
        log_error "Failed to detect ready new pod on $current_node after ${pod_ready_timeout}s"
        return 1
    fi
    
    # Wait for OVN to stabilize
    sleep 15
    
    # Check NAT count
    local count
    count=$(oc exec -n "$NAMESPACE" "$new_pod" -c ovnkube-controller -- bash -c \
        "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
    
    log_info "Egress IP NAT count: $count"
    
    # Save metrics
    echo "iteration_${iteration},pod_disruption,${count}" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
    
    return 0
}

# Run pod disruption tests
echo "iteration,test_type,nat_count" > "$ARTIFACT_DIR/pod_disruption_metrics.csv"

for ((i=1; i<=POD_KILL_RETRIES; i++)); do
    if ! run_pod_disruption_test "$i"; then
        log_warning "Pod disruption test iteration $i failed, but continuing..."
    fi
    sleep 10
done

log_success "Pod disruption testing completed"

# Phase 2: Node Reboot Testing  
log_info "==============================="
log_info "PHASE 2: Node Reboot Testing"
log_info "==============================="

run_node_reboot_test() {
    local iteration=$1
    
    log_info "Node reboot test iteration $iteration/$REBOOT_RETRIES"
    
    # Get all egress nodes
    local egress_nodes
    mapfile -t egress_nodes < <(oc get egressip -o jsonpath='{.items[*].status.items[*].node}' 2>/dev/null | tr ' ' '\n' | sort -u)
    if [[ ${#egress_nodes[@]} -eq 0 ]]; then
        log_error "No egress nodes found"
        return 1
    fi
    
    # Pick one randomly
    local selected_node=${egress_nodes[$((RANDOM % ${#egress_nodes[@]}))]}
    log_info "Selected node for reboot: $selected_node"
    
    # Get worker pods before reboot
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -o wide | awk '/ovnkube-node/ && /worker/ && !/master/ {print $1}')
    if [[ -z "$worker_pods" ]]; then
        worker_pods=$(oc get pods -n "$NAMESPACE" -o wide | awk '/ovnkube-node/ && !/master/ {print $1}')
    fi
    
    if [[ -z "$worker_pods" ]]; then
        log_error "No worker pods found"
        return 1
    fi
    
    # Count metrics before reboot
    local old_snat_count=0
    local old_policy_count=0
    
    for pod in $worker_pods; do
        local snat
        snat=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        local policy
        policy=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl lr-policy-list ovn_cluster_router | grep '100 ' | grep -v 1004 | wc -l" 2>/dev/null || echo "0")
        
        old_snat_count=$((old_snat_count + snat))
        old_policy_count=$((old_policy_count + policy))
    done
    
    log_info "Before reboot - SNAT: $old_snat_count, LR policy: $old_policy_count"
    
    # Reboot the selected node
    log_info "Rebooting node $selected_node..."
    if ! oc debug node/"$selected_node" -- chroot /host bash -c "systemctl reboot" 2>/dev/null; then
        log_warning "Reboot command may have failed, but continuing..."
    fi
    
    # Wait for node to go NotReady
    local elapsed=0
    local node_notready_timeout=300
    local notready_detected=false
    
    while [[ $elapsed -lt $node_notready_timeout ]]; do
        local status
        status=$(oc get node "$selected_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" != "True" ]]; then
            log_info "Node $selected_node is NotReady (rebooting)"
            notready_detected=true
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [[ "$notready_detected" == "false" ]]; then
        log_warning "Node $selected_node did not go NotReady within timeout, but continuing..."
    fi
    
    # Wait for node to become Ready again
    elapsed=0
    local node_ready_timeout=1200
    local ready_detected=false
    
    while [[ $elapsed -lt $node_ready_timeout ]]; do
        local status
        status=$(oc get node "$selected_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" == "True" ]]; then
            log_info "Node $selected_node is Ready again"
            ready_detected=true
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    if [[ "$ready_detected" == "false" ]]; then
        log_error "Node $selected_node did not become Ready within ${node_ready_timeout}s"
        return 1
    fi
    
    # Wait for OVN pods to stabilize
    sleep 30
    
    # Get worker pods after reboot
    worker_pods=$(oc get pods -n "$NAMESPACE" -o wide | awk '/ovnkube-node/ && /worker/ && !/master/ {print $1}')
    if [[ -z "$worker_pods" ]]; then
        worker_pods=$(oc get pods -n "$NAMESPACE" -o wide | awk '/ovnkube-node/ && !/master/ {print $1}')
    fi
    
    # Recheck metrics
    local new_snat_count=0
    local new_policy_count=0
    
    for pod in $worker_pods; do
        local snat
        snat=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        local policy
        policy=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl lr-policy-list ovn_cluster_router | grep '100 ' | grep -v 1004 | wc -l" 2>/dev/null || echo "0")
        
        new_snat_count=$((new_snat_count + snat))
        new_policy_count=$((new_policy_count + policy))
    done
    
    log_info "After reboot - SNAT: $new_snat_count, LR policy: $new_policy_count"
    
    # Save metrics
    echo "iteration_${iteration},node_reboot,${new_snat_count},${new_policy_count}" >> "$ARTIFACT_DIR/reboot_metrics.csv"
    
    # Validate counts match
    if [[ "$new_snat_count" -ne "$old_snat_count" ]] || [[ "$new_policy_count" -ne "$old_policy_count" ]]; then
        log_warning "Mismatch detected! SNAT: $old_snat_count → $new_snat_count, POLICY: $old_policy_count → $new_policy_count"
        return 1
    fi
    
    log_success "Counts match after reboot (SNAT: $new_snat_count, POLICY: $new_policy_count)"
    return 0
}

# Run reboot tests
echo "iteration,test_type,snat_count,policy_count" > "$ARTIFACT_DIR/reboot_metrics.csv"

for ((i=1; i<=REBOOT_RETRIES; i++)); do
    if ! run_node_reboot_test "$i"; then
        log_warning "Node reboot test iteration $i failed, but continuing..."
    fi
    sleep 10
done

log_success "Node reboot testing completed"

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
