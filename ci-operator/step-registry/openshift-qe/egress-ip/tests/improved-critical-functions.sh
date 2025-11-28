#!/bin/bash

# Improved Critical Functions for Egress IP Testing
# These functions address the major issues found in the original script

# Enhanced prerequisite checking with detailed validation
check_prerequisites() {
    log_info "Validating test prerequisites..."
    
    # Check if required tools are available
    local required_tools=("oc" "jq" "timeout")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error_exit "$tool command not found - required for test execution"
        fi
    done
    
    # Validate cluster connectivity with timeout
    if ! timeout 30 oc cluster-info &>/dev/null; then
        error_exit "Cannot connect to OpenShift cluster within 30s. Please check kubeconfig."
    fi
    
    # Check namespace access
    if ! oc get namespace "$NAMESPACE" &>/dev/null; then
        error_exit "Cannot access namespace $NAMESPACE"
    fi
    
    # Validate egress IP exists and is properly configured
    if ! oc get egressip "$EIP_NAME" &>/dev/null; then
        error_exit "Egress IP '$EIP_NAME' not found. Please run setup first."
    fi
    
    log_success "Prerequisites validation completed"
}

# Enhanced node name validation with comprehensive checks
validate_node_name() {
    local node_name="$1"
    
    # Check basic format
    if ! [[ "$node_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid node name format: $node_name"
        return 1
    fi
    
    # Verify node exists in cluster
    if ! oc get node "$node_name" &>/dev/null; then
        log_error "Node $node_name does not exist in cluster"
        return 1
    fi
    
    # Check if node is in Ready state
    local node_status
    node_status=$(oc get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$node_status" != "True" ]]; then
        log_warning "Node $node_name is not in Ready state (current: $node_status)"
    fi
    
    return 0
}

# Improved workload setup with better error handling and validation
setup_test_workload() {
    log_info "Creating test namespace and workload to generate egress traffic..."
    
    # Check if namespace already exists and clean it up
    if oc get namespace test-egress &>/dev/null; then
        log_warning "Test namespace already exists, cleaning up..."
        cleanup_test_workload
        sleep 10  # Allow time for cleanup
    fi
    
    # Create test namespace with proper labels
    cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test-egress
  labels:
    egress: $EIP_NAME
    test-type: egress-workload
---
apiVersion: v1
kind: Pod
metadata:
  name: test-workload
  namespace: test-egress
  labels:
    app: egress-test
    test-type: workload
spec:
  containers:
  - name: busybox
    image: busybox:latest
    command: ["sh", "-c"]
    args: 
    - |
      while true; do
        echo "Testing egress connectivity at \$(date)"
        # Use configurable targets to avoid external dependencies in restricted environments
        target1="\${EGRESS_TEST_TARGET1:-google.com}"
        target2="\${EGRESS_TEST_TARGET2:-redhat.com}"
        
        # Test with timeout and better error handling
        if timeout 15 wget -q --spider --timeout=10 "\$target1" 2>/dev/null; then
          echo "Successfully reached \$target1"
        else
          echo "Failed to reach \$target1"
        fi
        
        if timeout 15 wget -q --spider --timeout=10 "\$target2" 2>/dev/null; then
          echo "Successfully reached \$target2"
        else
          echo "Failed to reach \$target2"
        fi
        
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
    env:
    - name: EGRESS_TEST_TARGET1
      value: "${EGRESS_TEST_TARGET1:-google.com}"
    - name: EGRESS_TEST_TARGET2
      value: "${EGRESS_TEST_TARGET2:-redhat.com}"
  restartPolicy: Always
EOF

    if [[ $? -ne 0 ]]; then
        log_error "Failed to create test workload"
        return 1
    fi

    # Wait for pod to be ready with improved checking
    log_info "Waiting for test workload to be ready..."
    local elapsed=0
    local ready_conditions=0
    
    while [[ $elapsed -lt $WORKLOAD_READY_TIMEOUT ]]; do
        # Check multiple readiness conditions
        local phase status ready_condition
        
        phase=$(oc get pod test-workload -n test-egress -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        ready_condition=$(oc get pod test-workload -n test-egress -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        # Count how many conditions are met
        ready_conditions=0
        [[ "$phase" == "Running" ]] && ((ready_conditions++))
        [[ "$ready_condition" == "True" ]] && ((ready_conditions++))
        
        if [[ $ready_conditions -eq 2 ]]; then
            log_success "Test workload is fully ready and generating egress traffic"
            
            # Verify the pod is actually generating traffic
            sleep 5
            local recent_logs
            recent_logs=$(oc logs test-workload -n test-egress --tail=3 2>/dev/null || echo "")
            if [[ -n "$recent_logs" ]]; then
                log_info "Workload activity confirmed:"
                echo "$recent_logs" | sed 's/^/  /'
            fi
            
            return 0
        fi
        
        # Log progress every 30 seconds
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            log_info "Workload readiness progress: Phase=$phase, Ready=$ready_condition ($ready_conditions/2 conditions met)"
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    # Log final status for debugging
    log_error "Test workload not ready within ${WORKLOAD_READY_TIMEOUT}s"
    log_info "Final workload status:"
    oc describe pod test-workload -n test-egress 2>/dev/null | head -20 || log_error "Failed to get pod description"
    
    log_warning "Continuing with tests despite workload readiness issues..."
    return 0
}

# Enhanced cleanup with verification and forced cleanup
cleanup_test_workload() {
    log_info "Cleaning up test workload..."
    
    if ! oc get namespace test-egress &>/dev/null; then
        log_info "Test namespace doesn't exist, nothing to clean up"
        return 0
    fi
    
    # Graceful deletion first
    oc delete namespace test-egress --ignore-not-found=true --timeout=60s 2>/dev/null || {
        log_warning "Graceful namespace deletion failed, attempting forced cleanup"
        
        # Force delete pods first
        oc delete pods --all -n test-egress --force --grace-period=0 2>/dev/null || true
        
        # Then delete namespace with no grace period
        oc delete namespace test-egress --force --grace-period=0 2>/dev/null || true
    }
    
    # Wait for namespace deletion with progress tracking
    local cleanup_elapsed=0
    local last_status=""
    
    while [[ $cleanup_elapsed -lt $CLEANUP_TIMEOUT ]]; do
        if ! oc get namespace test-egress &>/dev/null; then
            log_success "Test namespace successfully deleted"
            return 0
        fi
        
        # Check deletion progress
        local current_status
        current_status=$(oc get namespace test-egress -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$current_status" != "$last_status" ]]; then
            log_info "Namespace deletion status: $current_status"
            last_status="$current_status"
        fi
        
        sleep 5
        cleanup_elapsed=$((cleanup_elapsed + 5))
    done
    
    log_error "Test namespace deletion timed out after ${CLEANUP_TIMEOUT}s"
    log_warning "Manual cleanup may be required for namespace test-egress"
    
    # Final attempt with detailed error information
    log_info "Final namespace status for debugging:"
    oc get namespace test-egress -o yaml 2>/dev/null | grep -A 10 "status:" || log_error "Failed to get namespace status"
    
    return 1
}

# Enhanced pod disruption test with better error handling
run_pod_disruption_test() {
    local iteration=$1
    
    log_info "Pod disruption test iteration $iteration/$POD_KILL_RETRIES"
    
    # Get current assigned node with validation
    local current_node
    current_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -z "$current_node" ]]; then
        log_error "Egress IP not assigned in iteration $iteration"
        return 1
    fi
    
    validate_node_name "$current_node" || return 1
    
    # Find ovnkube-node pod using more efficient method
    local pod_name
    pod_name=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node \
        --field-selector spec.nodeName="$current_node" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
    if [[ -z "$pod_name" ]]; then
        log_error "No ovnkube-node pod found on node $current_node"
        return 1
    fi
    
    # Validate pod is actually running before deletion
    local pod_phase
    pod_phase=$(oc get pod -n "$NAMESPACE" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$pod_phase" != "Running" ]]; then
        log_warning "Pod $pod_name is not in Running state (phase: $pod_phase), but proceeding with test"
    fi
    
    log_info "Deleting pod $pod_name on node $current_node..."
    
    # Delete pod with verification
    if ! oc delete pod -n "$NAMESPACE" "$pod_name" --ignore-not-found --wait=false; then
        log_error "Failed to delete pod $pod_name"
        return 1
    fi
    
    # Wait for old pod to actually terminate before checking for new pod
    local termination_wait=30
    local termination_elapsed=0
    
    log_info "Waiting for pod termination..."
    while [[ $termination_elapsed -lt $termination_wait ]]; do
        if ! oc get pod -n "$NAMESPACE" "$pod_name" &>/dev/null; then
            log_info "Old pod $pod_name successfully terminated"
            break
        fi
        sleep 2
        termination_elapsed=$((termination_elapsed + 2))
    done
    
    # Wait for new pod to be ready with enhanced validation
    local elapsed=0
    local new_pod=""
    local ready="false"
    local containers_ready=0
    local expected_containers=2  # ovnkube-controller and ovs
    
    log_info "Waiting for replacement pod to be ready..."
    while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
        # Get new pod
        new_pod=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node \
            --field-selector spec.nodeName="$current_node" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [[ -n "$new_pod" ]] && [[ "$new_pod" != "$pod_name" ]]; then
            # Check overall readiness
            ready=$(oc get pod -n "$NAMESPACE" "$new_pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "false")
            
            # Check container-specific readiness
            containers_ready=$(oc get pod -n "$NAMESPACE" "$new_pod" -o jsonpath='{.status.containerStatuses[?(@.ready==true)]' 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
            
            if [[ "$ready" == "true" ]] && [[ "$containers_ready" -eq "$expected_containers" ]]; then
                log_success "New pod $new_pod is ready with all $containers_ready containers"
                break
            fi
            
            # Log progress every 30 seconds
            if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
                log_info "Pod replacement progress: Pod=$new_pod, Ready=$ready, Containers=$containers_ready/$expected_containers"
            fi
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [[ -z "$new_pod" ]] || [[ "$new_pod" == "$pod_name" ]] || [[ "$ready" != "true" ]]; then
        log_error "Failed to detect ready new pod on $current_node after ${POD_READY_TIMEOUT}s"
        
        # Debug information
        log_info "Debug information:"
        log_info "  New pod: $new_pod"
        log_info "  Old pod: $pod_name" 
        log_info "  Ready status: $ready"
        log_info "  Containers ready: $containers_ready/$expected_containers"
        
        return 1
    fi
    
    # Wait for OVN to stabilize with verification
    log_info "Waiting ${OVN_STABILIZATION_WAIT}s for OVN to stabilize..."
    sleep "$OVN_STABILIZATION_WAIT"
    
    # Verify OVN connectivity before checking NAT rules
    local ovn_check_attempts=3
    for ((attempt=1; attempt<=ovn_check_attempts; attempt++)); do
        if oc exec -n "$NAMESPACE" "$new_pod" -c ovnkube-controller -- timeout 10 ovn-nbctl show &>/dev/null; then
            log_success "OVN connectivity verified"
            break
        else
            log_warning "OVN connectivity check failed (attempt $attempt/$ovn_check_attempts)"
            if [[ $attempt -eq $ovn_check_attempts ]]; then
                log_error "Failed to verify OVN connectivity after $ovn_check_attempts attempts"
                return 1
            fi
            sleep 5
        fi
    done
    
    # Check NAT count with error handling
    local count
    count=$(oc exec -n "$NAMESPACE" "$new_pod" -c ovnkube-controller -- \
        timeout 15 bash -c "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
    
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        log_error "Invalid NAT count response: $count"
        count="0"
    fi
    
    log_info "Egress IP NAT count after pod disruption: $count"
    
    # Save metrics with additional context
    echo "iteration_${iteration},pod_disruption,${count},${new_pod},$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
    
    return 0
}

# Export functions for use in main script
export -f check_prerequisites validate_node_name setup_test_workload cleanup_test_workload run_pod_disruption_test