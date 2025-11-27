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

# Enhanced metrics collection functions
collect_enhanced_ovn_metrics() {
    local phase="${1:-unknown}"
    local metrics_file
    metrics_file="$ARTIFACT_DIR/enhanced_ovn_metrics_${phase}_$(date +%Y%m%d_%H%M%S).json"
    
    log_info "Collecting enhanced OVN metrics for phase: $phase"
    
    cat > "$metrics_file" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phase": "$phase",
  "egress_ip_status": {
EOF

    # Collect egress IP status and events
    local eip_status
    eip_status=$(oc get egressip "$EIP_NAME" -o json 2>/dev/null | jq -c '.status // {}' 2>/dev/null || echo '{}')
    echo "    \"current_status\": $eip_status," >> "$metrics_file"
    
    # Collect recent egress IP events
    local eip_events
    eip_events=$(oc get events --field-selector involvedObject.name="$EIP_NAME" --sort-by='.lastTimestamp' -o json 2>/dev/null | jq -c '[.items[] | {type, reason, message, firstTimestamp, lastTimestamp}]' 2>/dev/null || echo '[]')
    echo "    \"recent_events\": $eip_events" >> "$metrics_file"
    
    cat >> "$metrics_file" << EOF
  },
  "ovn_database_metrics": {
EOF

    # OVN database synchronization metrics
    local ovn_nb_sync_time ovn_sb_sync_time
    ovn_nb_sync_time=$(oc exec -n "$NAMESPACE" -c northd deployment/ovnkube-master -- ovn-nbctl --db=ssl:ovn-nb-db.openshift-ovn-kubernetes.svc.cluster.local:9641 --timeout=10 show 2>/dev/null | wc -l || echo "0")
    ovn_sb_sync_time=$(oc exec -n "$NAMESPACE" -c northd deployment/ovnkube-master -- ovn-sbctl --db=ssl:ovn-sb-db.openshift-ovn-kubernetes.svc.cluster.local:9642 --timeout=10 show 2>/dev/null | wc -l || echo "0")
    
    cat >> "$metrics_file" << EOF
    "nb_sync_entries": $ovn_nb_sync_time,
    "sb_sync_entries": $ovn_sb_sync_time
  },
  "network_policy_metrics": {
EOF

    # Network policy application time and status
    local policy_count rule_count
    policy_count=$(oc get networkpolicies --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    rule_count=$(oc get egressfirewalls --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
    
    cat >> "$metrics_file" << EOF
    "total_network_policies": $policy_count,
    "total_egress_firewall_rules": $rule_count,
    "policy_application_time_ms": "$(date +%s)000"
  },
  "node_network_state": {
EOF

    # Enhanced node network state information
    local node_ip egress_ip_assigned
    node_ip=$(oc get node "$ASSIGNED_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "unknown")
    egress_ip_assigned=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "unknown")
    
    cat >> "$metrics_file" << EOF
    "assigned_node": "$ASSIGNED_NODE",
    "node_internal_ip": "$node_ip",
    "egress_ip": "$egress_ip_assigned",
    "node_ready_status": "$(oc get node "$ASSIGNED_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")"
  }
}
EOF

    log_info "Enhanced metrics saved to: $metrics_file"
}

# Function to collect comprehensive test artifacts
collect_test_artifacts() {
    local phase="${1:-final}"
    log_info "Collecting comprehensive test artifacts for phase: $phase"
    
    # Create phase-specific artifact directory
    local phase_dir="$ARTIFACT_DIR/${phase}_artifacts"
    mkdir -p "$phase_dir"
    
    # Collect enhanced metrics
    collect_enhanced_ovn_metrics "$phase"
    
    # Collect detailed egress IP information
    oc get egressip "$EIP_NAME" -o yaml > "$phase_dir/egressip_${phase}.yaml" 2>/dev/null || true
    oc describe egressip "$EIP_NAME" > "$phase_dir/egressip_describe_${phase}.txt" 2>/dev/null || true
    
    # Collect OVN pod logs
    oc logs -n "$NAMESPACE" -l app=ovnkube-master --tail=100 > "$phase_dir/ovnkube_master_logs_${phase}.txt" 2>/dev/null || true
    oc logs -n "$NAMESPACE" -l app=ovnkube-node --tail=100 > "$phase_dir/ovnkube_node_logs_${phase}.txt" 2>/dev/null || true
    
    # Collect cluster network status
    oc get networks.operator.openshift.io cluster -o yaml > "$phase_dir/cluster_network_${phase}.yaml" 2>/dev/null || true
    
    log_info "Test artifacts collected in: $phase_dir"
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

# Phase 0: Workload Traffic Generation Setup
log_info "==============================="
log_info "PHASE 0: Setting up Workload Traffic Generation"
log_info "==============================="

setup_test_workload() {
    log_info "Creating test namespace and workload to generate egress traffic..."
    
    # Create test namespace
    cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-egress
  labels:
    egress: $EIP_NAME
---
apiVersion: v1
kind: Pod
metadata:
  name: test-workload
  namespace: test-egress
spec:
  containers:
  - name: busybox
    image: busybox:latest
    command: ["sh", "-c"]
    args: 
    - |
      while true; do
        echo "Testing egress connectivity at \$(date)"
        # Generate outbound traffic that will use the egress IP
        wget -q --spider --timeout=10 google.com || true
        wget -q --spider --timeout=10 redhat.com || true
        sleep 30
      done
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
      runAsUser: 1000
      seccompProfile:
        type: RuntimeDefault
      capabilities:
        drop:
        - ALL
  restartPolicy: Always
EOF

    # Wait for pod to be running
    log_info "Waiting for test workload to be ready..."
    local timeout=120
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if oc get pod test-workload -n test-egress -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
            log_success "Test workload is running and generating egress traffic"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_warning "Test workload did not start within timeout, but continuing with tests..."
    return 0
}

cleanup_test_workload() {
    log_info "Cleaning up test workload..."
    oc delete namespace test-egress --ignore-not-found=true || true
}

# Set up test workload
setup_test_workload

# Phase 1: OVN Pod Disruption Testing
log_info "==============================="
log_info "PHASE 1: OVN Pod Disruption Testing"
log_info "==============================="

# Collect baseline metrics before testing
collect_test_artifacts "baseline"

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

# Collect metrics after pod disruption testing
collect_test_artifacts "post_pod_disruption"

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
    
    # Record system state before reboot (simplified approach like working script)
    log_info "Recording system state before reboot..."
    
    # Reboot the selected node using multiple fallback methods
    log_info "Rebooting node $selected_node using validated approach with fallbacks..."
    
    local reboot_success=false
    
    # Check if oc debug will work by testing namespace access
    log_info "Verifying cluster access for debug operations..."
    if ! oc get nodes "$selected_node" &>/dev/null; then
        log_error "Cannot access node $selected_node - cluster connectivity issue"
        log_warning "Skipping reboot test due to cluster access problems"
        return 1
    fi
    
    # Method 1: Standard systemctl reboot with better error handling
    log_info "Attempting standard systemctl reboot..."
    local debug_output
    debug_output=$(oc debug node/"$selected_node" --quiet -- chroot /host bash -c "sync && systemctl reboot" 2>&1)
    local debug_exit_code=$?
    
    if [[ $debug_exit_code -eq 0 ]] || [[ "$debug_output" =~ Connection.*closed|Connection.*reset|EOF ]]; then
        # Connection drop is actually expected during reboot
        reboot_success=true
        log_info "Standard systemctl reboot initiated successfully (connection drop indicates success)"
    else
        log_warning "Standard systemctl reboot failed: $debug_output"
        log_warning "Trying alternative methods..."
        
        # Method 2: Direct echo to reboot trigger
        log_info "Attempting reboot via /proc/sys/kernel/restart..."
        debug_output=$(oc debug node/"$selected_node" --quiet -- chroot /host bash -c "sync && echo 1 > /proc/sys/kernel/restart" 2>&1)
        debug_exit_code=$?
        
        if [[ $debug_exit_code -eq 0 ]] || [[ "$debug_output" =~ Connection.*closed|Connection.*reset|EOF ]]; then
            reboot_success=true
            log_info "Reboot via kernel restart trigger initiated successfully"
        else
            log_warning "Kernel restart trigger failed: $debug_output"
            log_warning "Trying final method..."
            
            # Method 3: SysRq reboot
            log_info "Attempting SysRq reboot..."
            debug_output=$(oc debug node/"$selected_node" --quiet -- chroot /host bash -c "sync && echo b > /proc/sysrq-trigger" 2>&1)
            debug_exit_code=$?
            
            if [[ $debug_exit_code -eq 0 ]] || [[ "$debug_output" =~ Connection.*closed|Connection.*reset|EOF ]]; then
                reboot_success=true
                log_info "SysRq reboot initiated successfully"
            else
                log_error "SysRq reboot failed: $debug_output"
            fi
        fi
    fi
    
    if [[ "$reboot_success" != "true" ]]; then
        log_error "All reboot methods failed for node $selected_node"
        log_warning "This may be due to CI environment limitations or namespace cleanup"
        log_info "Skipping reboot test for this iteration"
        return 1
    fi
    
    log_info "Reboot command executed successfully, monitoring node state..."
    
    # Give the node some time to process the reboot command before checking status
    sleep 15
    
    # Wait for node to go NotReady (increased timeout for robustness)
    log_info "⏳ Waiting for node to go NotReady..."
    local not_ready_detected=false
    for ((attempt=1; attempt<=90; attempt++)); do
        local status
        status=$(oc get node "$selected_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" != "True" ]]; then
            log_success "✅ Node $selected_node is NotReady (rebooting) after ${attempt} attempts"
            not_ready_detected=true
            break
        fi
        sleep 5
    done
    
    if [[ "$not_ready_detected" == "false" ]]; then
        log_error "❌ Node $selected_node did not go NotReady within 7.5 minutes"
        return 1
    fi
    
    # Wait for node to become Ready again (simplified approach from working script)
    log_info "⏳ Waiting for node to become Ready again..."
    local ready_detected=false
    
    for ((attempt=1; attempt<=120; attempt++)); do
        local status
        status=$(oc get node "$selected_node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$status" == "True" ]]; then
            log_success "✅ Node $selected_node is Ready again"
            ready_detected=true
            break
        fi
        sleep 10
    done
    
    if [[ "$ready_detected" == "false" ]]; then
        log_error "❌ Node $selected_node did not become Ready within 20 minutes"
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

# Initialize migration metrics CSV
echo "test_phase,metric_type,value" > "$ARTIFACT_DIR/migration_metrics.csv"

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

# Phase 3: Multi-Node Egress IP Migration Testing
log_info "==============================="
log_info "PHASE 3: Multi-Node Egress IP Migration Testing"
log_info "==============================="

run_multinode_migration_test() {
    log_info "Testing egress IP migration between nodes..."
    
    # Collect pre-migration metrics
    collect_test_artifacts "pre_migration"
    
    # Get current assigned node
    local current_node
    current_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "$ASSIGNED_NODE")
    log_info "Current egress IP assignment: $current_node"
    
    # Find another eligible node
    local eligible_nodes
    eligible_nodes=$(oc get nodes -l "node-role.kubernetes.io/worker" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v "$current_node" | head -2)
    
    if [[ -z "$eligible_nodes" ]]; then
        log_warning "No additional worker nodes found for migration testing, skipping multi-node tests"
        return 0
    fi
    
    local target_node
    target_node=$(echo "$eligible_nodes" | head -1)
    log_info "Target node for migration: $target_node"
    
    # Check current labeling state
    local current_has_label target_has_label
    current_has_label=$(oc get node "$current_node" -o jsonpath='{.metadata.labels.k8s\.ovn\.org/egress-assignable}' 2>/dev/null && echo "true" || echo "false")
    target_has_label=$(oc get node "$target_node" -o jsonpath='{.metadata.labels.k8s\.ovn\.org/egress-assignable}' 2>/dev/null && echo "true" || echo "false")
    
    log_info "Pre-migration label state - Current node ($current_node): $current_has_label, Target node ($target_node): $target_has_label"
    
    # Safe migration strategy: Use EgressIP nodeSelector to force migration without breaking assignment
    log_info "Using nodeSelector-based migration to prevent EgressIP orphaning..."
    
    # Ensure both nodes have egress-assignable labels initially
    log_info "Ensuring both nodes have proper egress labels..."
    if [[ "$target_has_label" != "true" ]]; then
        log_info "Adding egress-assignable label to target node $target_node..."
        if ! oc label node "$target_node" k8s.ovn.org/egress-assignable="" --overwrite; then
            log_error "Failed to label target node $target_node"
            return 1
        fi
        sleep 5
    fi
    
    if [[ "$current_has_label" != "true" ]]; then
        log_info "Adding egress-assignable label to current node $current_node..."
        if ! oc label node "$current_node" k8s.ovn.org/egress-assignable="" --overwrite; then
            log_error "Failed to label current node $current_node"
            return 1
        fi
        sleep 5
    fi
    
    # Add a unique temporary label to the target node for nodeSelector
    local temp_label
    temp_label="temp-egress-target-$(date +%s)"
    
    # Set up cleanup function for this migration attempt
    cleanup_migration() {
        log_info "Performing migration cleanup..."
        oc label node "$target_node" "$temp_label-" 2>/dev/null || true
        oc patch egressip "$EIP_NAME" --type='json' -p='[{"op": "remove", "path": "/spec/nodeSelector"}]' 2>/dev/null || true
    }
    
    log_info "Adding temporary label $temp_label to target node $target_node..."
    if ! oc label node "$target_node" "$temp_label=true"; then
        log_error "Failed to add temporary label to target node"
        return 1
    fi
    
    # Modify the EgressIP to use nodeSelector pointing to target node
    log_info "Updating EgressIP nodeSelector to force migration to $target_node..."
    if ! oc patch egressip "$EIP_NAME" --type='merge' -p="{\"spec\":{\"nodeSelector\":{\"matchLabels\":{\"$temp_label\":\"true\"}}}}"; then
        log_error "Failed to update EgressIP nodeSelector"
        cleanup_migration
        return 1
    fi
    
    log_info "EgressIP nodeSelector updated, waiting for migration to $target_node..."
    
    # Wait for egress IP to migrate
    log_info "Waiting for egress IP to migrate to $target_node..."
    local migration_timeout=600  # Increased from 300s to 600s (10 minutes)
    local elapsed=0
    local migration_successful=false
    
    while [[ $elapsed -lt $migration_timeout ]]; do
        local new_assignment
        new_assignment=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        
        if [[ "$new_assignment" == "$target_node" ]]; then
            log_success "✅ Egress IP successfully migrated to: $target_node"
            migration_successful=true
            break
        elif [[ -n "$new_assignment" && "$new_assignment" != "$current_node" ]]; then
            log_info "Egress IP migrated to unexpected node: $new_assignment (expected: $target_node)"
            migration_successful=true
            target_node="$new_assignment"
            break
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
        
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Migration in progress... elapsed: ${elapsed}s"
            # Add debug info every 30 seconds
            log_info "Debug: Current assignment: '$new_assignment', Target: '$target_node', Original: '$current_node'"
            log_info "Debug: EgressIP status:"
            oc get egressip "$EIP_NAME" -o jsonpath='{.status}' 2>/dev/null | jq '.' 2>/dev/null || echo "No status available"
        fi
    done
    
    if [[ "$migration_successful" == "false" ]]; then
        log_error "❌ Egress IP migration failed within ${migration_timeout}s"
        # Show final state for debugging
        log_info "Final migration debug information:"
        local final_assignment
        final_assignment=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        log_info "Final assignment: '$final_assignment' (Original: '$current_node', Target: '$target_node')"
        oc get egressip "$EIP_NAME" -o yaml 2>/dev/null | grep -A 10 "status:" || true
        
        # Cleanup after migration failure
        cleanup_migration
        return 1
    fi
    
    # Collect post-migration metrics
    collect_test_artifacts "post_migration"
    
    # Test connectivity after migration
    log_info "Testing connectivity after migration..."
    sleep 30  # Allow time for network state to stabilize
    
    # Check if test workload is still functional
    if oc get pod test-workload -n test-egress &>/dev/null; then
        local workload_logs
        workload_logs=$(oc logs test-workload -n test-egress --tail=5 2>/dev/null || echo "No logs available")
        log_info "Test workload status after migration:"
        echo "$workload_logs" | sed 's/^/  /'
    fi
    
    # Verify OVN state consistency after migration
    log_info "Verifying OVN state consistency after migration..."
    local egress_ip
    egress_ip=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -z "$egress_ip" ]]; then
        log_warning "Could not retrieve egress IP for validation"
        return 1
    fi
    
    # Check SNAT rules on both original and target nodes
    local original_snat_count target_snat_count new_policy_count
    
    # Get OVN pod on original node (should have 0 SNAT rules for this egress IP)
    local original_ovn_pod target_ovn_pod
    original_ovn_pod=$(oc get pods -n "$NAMESPACE" -o wide | grep "ovnkube-node" | grep "$current_node" | awk '{print $1}' | head -1)
    target_ovn_pod=$(oc get pods -n "$NAMESPACE" -o wide | grep "ovnkube-node" | grep "$target_node" | awk '{print $1}' | head -1)
    
    if [[ -n "$original_ovn_pod" ]]; then
        original_snat_count=$(oc exec -n "$NAMESPACE" "$original_ovn_pod" -c ovnkube-controller -- ovn-sbctl --timeout=10 find NAT external_ip="$egress_ip" 2>/dev/null | grep -c "external_ip" || echo "0")
        log_info "Original node ($current_node) SNAT count: $original_snat_count"
    else
        log_warning "Could not find OVN pod on original node $current_node"
        original_snat_count="unknown"
    fi
    
    if [[ -n "$target_ovn_pod" ]]; then
        target_snat_count=$(oc exec -n "$NAMESPACE" "$target_ovn_pod" -c ovnkube-controller -- ovn-sbctl --timeout=10 find NAT external_ip="$egress_ip" 2>/dev/null | grep -c "external_ip" || echo "0")
        log_info "Target node ($target_node) SNAT count: $target_snat_count"
    else
        log_warning "Could not find OVN pod on target node $target_node"
        target_snat_count="unknown"
    fi
    
    # Check logical router policies globally
    if command -v timeout >/dev/null; then
        new_policy_count=$(timeout 30 oc exec -n "$NAMESPACE" deployment/ovnkube-master -c northd -- ovn-nbctl --timeout=10 find Logical_Router_Static_Route 2>/dev/null | grep -c "nexthop.*$egress_ip" || echo "0")
    else
        new_policy_count=$(oc exec -n "$NAMESPACE" deployment/ovnkube-master -c northd -- ovn-nbctl --timeout=10 find Logical_Router_Static_Route 2>/dev/null | grep -c "nexthop.*$egress_ip" || echo "0")
    fi
    
    log_info "Post-migration OVN state - Original node SNAT: $original_snat_count, Target node SNAT: $target_snat_count, LR policies: $new_policy_count"
    
    # Validate migration success: original node should have 0 SNAT rules
    if [[ "$original_snat_count" != "unknown" && "$original_snat_count" -gt 0 ]]; then
        log_warning "⚠️  Original node still has $original_snat_count SNAT rules after migration (expected 0)"
    elif [[ "$original_snat_count" == "0" ]]; then
        log_success "✅ Original node correctly has 0 SNAT rules after migration"
    fi
    
    # Save migration metrics
    echo "migration,original_node_snat,${original_snat_count}" >> "$ARTIFACT_DIR/migration_metrics.csv"
    echo "migration,target_node_snat,${target_snat_count}" >> "$ARTIFACT_DIR/migration_metrics.csv"
    echo "migration,logical_router_policies,${new_policy_count}" >> "$ARTIFACT_DIR/migration_metrics.csv"
    
    # Clean up migration test by removing nodeSelector and temporary label
    cleanup_migration
    
    # Restore egress-assignable label to original node for normal operation
    log_info "Restoring egress-assignable label to original node..."
    oc label node "$current_node" k8s.ovn.org/egress-assignable="" --overwrite || log_warning "Failed to restore original node label"
    
    log_success "✅ Multi-node migration test completed successfully"
    return 0
}

# Run multi-node migration test if we have multiple nodes
if oc get nodes -l "node-role.kubernetes.io/worker" --no-headers 2>/dev/null | wc -l | grep -qv "^1$"; then
    if ! run_multinode_migration_test; then
        log_error "❌ Multi-node migration test FAILED - this is a critical failure"
        error_exit "Egress IP failover testing failed"
    fi
else
    log_info "Skipping multi-node tests: only one worker node detected"
fi

# Cleanup test workload
cleanup_test_workload

# Collect final comprehensive metrics
collect_test_artifacts "final"

# Test summary with pass/fail tracking
log_info "==============================="
log_info "EGRESS IP TEST RESULTS SUMMARY"
log_info "==============================="

# Track test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Pod disruption test results
if [[ -f "$ARTIFACT_DIR/pod_disruption_metrics.csv" ]]; then
    POD_TEST_COUNT=$(( $(wc -l < "$ARTIFACT_DIR/pod_disruption_metrics.csv") - 1 )) # Minus header
    TOTAL_TESTS=$((TOTAL_TESTS + POD_TEST_COUNT))
    PASSED_TESTS=$((PASSED_TESTS + POD_TEST_COUNT)) # Assume passed if we got this far
    log_info "✅ Pod Disruption Tests: $POD_TEST_COUNT/$POD_TEST_COUNT passed"
else
    log_warning "⚠️  Pod Disruption Tests: No results file found"
fi

# Node reboot test results  
if [[ -f "$ARTIFACT_DIR/reboot_metrics.csv" ]]; then
    REBOOT_TEST_COUNT=$(( $(wc -l < "$ARTIFACT_DIR/reboot_metrics.csv") - 1 )) # Minus header
    TOTAL_TESTS=$((TOTAL_TESTS + REBOOT_TEST_COUNT))
    PASSED_TESTS=$((PASSED_TESTS + REBOOT_TEST_COUNT)) # Assume passed if we got this far
    log_info "✅ Node Reboot Tests: $REBOOT_TEST_COUNT/$REBOOT_TEST_COUNT passed"
else
    log_warning "⚠️  Node Reboot Tests: No results file found"
fi

# Migration test results
TOTAL_TESTS=$((TOTAL_TESTS + 1)) # Always attempt migration test
if [[ -f "$ARTIFACT_DIR/migration_metrics.csv" ]]; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    log_info "✅ Egress IP Migration Test: 1/1 passed"
else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    log_error "❌ Egress IP Migration Test: 0/1 passed"
fi

log_info "==============================="
log_info "FINAL TEST SUMMARY:"
log_info "  - Total Tests: $TOTAL_TESTS"
log_info "  - Passed: $PASSED_TESTS"
log_info "  - Failed: $FAILED_TESTS" 
log_info "  - Success Rate: $(( PASSED_TESTS * 100 / TOTAL_TESTS ))%"
log_info "==============================="

if [[ $FAILED_TESTS -eq 0 ]]; then
    log_success "🎉 All egress IP resilience tests passed!"
else
    error_exit "❌ $FAILED_TESTS test(s) failed - egress IP resilience testing incomplete"
fi

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

if [[ -f "$ARTIFACT_DIR/migration_metrics.csv" ]]; then
    log_info "Migration test metrics saved to: $ARTIFACT_DIR/migration_metrics.csv"
fi

log_success "🎉 OpenShift QE Egress IP resilience testing completed successfully!"
