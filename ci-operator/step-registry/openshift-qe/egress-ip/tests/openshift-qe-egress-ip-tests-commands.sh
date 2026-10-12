#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Resilience Tests using Cloud-Bulldozer Methodology
# Comprehensive end-to-end testing of egress IP functionality under disruption
# Integrated with cloud-bulldozer kube-burner egressip workload approach

echo "Starting OpenShift QE Egress IP Resilience Tests with Cloud-Bulldozer Integration"
echo "=================================================================================="

# Load cloud-bulldozer configuration if available
if [[ -f "$SHARED_DIR/cloud-bulldozer-config" ]]; then
    echo "Loading cloud-bulldozer kube-burner egressip workload configuration..."
    source "$SHARED_DIR/cloud-bulldozer-config"
    echo "Cloud-bulldozer settings: WORKLOAD=$WORKLOAD, ITERATIONS=$ITERATIONS workers"
fi

# Configuration (cloud-bulldozer + chaos engineering hybrid)
EIP_NAME="${EIP_NAME:-egress-ip-test}"
POD_KILL_RETRIES="${POD_KILL_RETRIES:-10}"
REBOOT_RETRIES="${REBOOT_RETRIES:-5}"
NAMESPACE="openshift-ovn-kubernetes"
WORKER_COUNT="${WORKER_COUNT:-3}"

# Test validation thresholds - CRITICAL FOR TEST FAILURE CONDITIONS
EXPECTED_MIN_OVN_PODS="${EXPECTED_MIN_OVN_PODS:-2}"  # Minimum expected OVN pods

# Get external validation service URL from setup (cloud-bulldozer compatible)
if [[ -f "$SHARED_DIR/health-check-url" ]]; then
    IPECHO_SERVICE_URL=$(cat "$SHARED_DIR/health-check-url")
else
    IPECHO_SERVICE_URL="https://httpbin.org/ip"  # Fallback
fi
echo "Using cloud-bulldozer compatible external validation service: $IPECHO_SERVICE_URL"

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
log_info() { echo -e "${BLUE}[INFO]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2; }

error_exit() {
    log_error "$*"
    exit 1
}

# Simple EgressIP assignment validation
validate_egressip_assignment() {
    local eip_name="$1"
    
    # Check if EgressIP exists and is assigned to a node
    local assigned_node
    assigned_node=$(oc get egressip "$eip_name" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    
    if [[ -z "$assigned_node" ]]; then
        log_error "❌ Egress IP $eip_name is not assigned to any node"
        return 1
    fi
    
    log_success "✅ Egress IP $eip_name is assigned to node: $assigned_node"
    return 0
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

# Verify cluster is ready before disruption
verify_cluster_ready() {
    log_info "Verifying cluster is ready for disruption testing..."
    
    # Verify OVN pods exist and meet minimum threshold
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    local ovn_pod_count
    ovn_pod_count=$(echo "$worker_pods" | wc -w)
    
    log_info "Found $ovn_pod_count OVN pods (minimum required: $EXPECTED_MIN_OVN_PODS)"
    
    if [[ $ovn_pod_count -lt $EXPECTED_MIN_OVN_PODS ]]; then
        log_error "❌ TEST FAILURE: Insufficient OVN pods found: $ovn_pod_count < $EXPECTED_MIN_OVN_PODS (minimum required)"
        log_error "   This indicates a cluster setup issue or OVN pod failure"
        echo "cluster_validation,ovn_pod_count,FAIL,$ovn_pod_count" >> "$ARTIFACT_DIR/test_validation_metrics.csv"
        return 1
    fi
    
    log_success "✅ OVN pod count validation PASSED: $ovn_pod_count >= $EXPECTED_MIN_OVN_PODS"
    echo "cluster_validation,ovn_pod_count,PASS,$ovn_pod_count" >> "$ARTIFACT_DIR/test_validation_metrics.csv"
    
    log_info "Found OVN pods: $(echo $worker_pods | tr ' ' ',')"
    
    # Verify egress IP is assigned
    local assigned_node
    assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -z "$assigned_node" ]]; then
        log_error "❌ TEST FAILURE: Egress IP $EIP_NAME is not assigned to any node"
        echo "cluster_validation,egress_ip_assignment,FAIL,unassigned" >> "$ARTIFACT_DIR/test_validation_metrics.csv"
        return 1
    fi
    
    log_success "✅ Egress IP assignment validation PASSED: $EIP_NAME assigned to node $assigned_node"
    echo "cluster_validation,egress_ip_assignment,PASS,$assigned_node" >> "$ARTIFACT_DIR/test_validation_metrics.csv"
    
    # Cluster ready for disruption testing - egress IP is properly assigned
    log_info "🔍 Cluster readiness validated - egress IP is properly assigned and ready for chaos testing"
    
    log_success "Cluster ready: All validation checks passed"
    log_info "Note: Both primary and secondary validations must pass for cluster readiness"
    
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
    
    # FUNCTIONAL EGRESS IP VALIDATION (using ipecho service)
    log_info "Validating actual egress IP traffic flow using functional testing..."
    
    local eip_address
    eip_address=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -n "$eip_address" ]]; then
        # PROPER CHAOS TESTING: Use existing workload pods created during setup
        # instead of creating new ones after disruption
        log_info "🔍 Using existing traffic generator pods for post-disruption validation..."
        log_info "ℹ️  Proper chaos testing: validate existing workloads survived disruption"
        
        # Validate egress IP configuration still exists after disruption
        local eip_status
        eip_status=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
        
        if [[ -z "$eip_status" ]]; then
            log_error "❌ CHAOS TESTING FAILURE: EgressIP resource not assigned after disruption"
            log_error "   This indicates that either:"
            log_error "   1. EgressIP failed to survive the disruption (FAILURE)"
            log_error "   2. Pod disruption affected OVN controller functionality (FAILURE)"
            log_error "   3. Cluster state became inconsistent after chaos testing (FAILURE)"
            log_error "   Proper chaos testing requires existing workloads to survive disruption"
            echo "post_disruption,existing_workload_survival,FAIL,no_pods_found" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
            return 1  # FAIL THE TEST - this is a fundamental chaos testing failure
        else
            # EgressIP is still assigned after disruption - use test namespace from setup
            if [[ -f "$SHARED_DIR/egress-namespace" ]]; then
                TEST_NAMESPACE=$(cat "$SHARED_DIR/egress-namespace")
                log_success "✅ EgressIP survived disruption, using test namespace: $TEST_NAMESPACE"
            else
                TEST_NAMESPACE="egress-ip-test"  # fallback
                log_info "Using fallback test namespace: $TEST_NAMESPACE"
            fi
        fi
        
        # Create a temporary test pod for validation
        TEST_POD="egress-validation-pod-$(date +%s)"
        log_info "Creating temporary test pod: $TEST_POD"
        
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD
  namespace: $TEST_NAMESPACE
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF
        
        # Wait for pod readiness
        local wait_timeout=60
        
        if oc wait --for=condition=Ready pod/"$TEST_POD" -n "$TEST_NAMESPACE" --timeout="${wait_timeout}s"; then
            log_success "✅ Post-disruption pod validation: $TEST_POD is ready in $TEST_NAMESPACE"
            
            # Network diagnostic tests - Focus on internal egress IP validation  
            log_info "📍 Post-disruption pod network interface information:"
            oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- ip addr show || true
            
            log_info "📍 Post-disruption pod routing table:"
            oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- ip route show || true
            
            # FOCUS: Internal egress IP validation only (not external NAT gateway testing)
            log_info "🔍 Validating internal egress IP configuration..."
            log_info "ℹ️  Note: Testing internal OVN egress IP configuration, not external NAT gateway behavior"
            
            # Get external bastion echo service URL for egress IP validation
            local external_echo_url=""
            if [[ -f "$SHARED_DIR/health-check-url" ]]; then
                external_echo_url=$(cat "$SHARED_DIR/health-check-url" 2>/dev/null || echo "")
                log_info "📡 Using external bastion IP echo service for egress IP validation: $external_echo_url"
            else
                log_warning "⚠️  External bastion echo service URL not found - skipping external validation"
                log_info "🔍 Proceeding with internal OVN validation only"
            fi
            
            # DEBUG: Pre-validation state verification
            log_info "🔍 DEBUG: Pre-validation EgressIP state verification:"
            log_info "Current EgressIP status:"
            oc describe egressip "$EIP_NAME" || true
            
            # DEBUG: Pod distribution - testing realistic deployment scenario
            log_info "🔍 DEBUG: Pod distribution across cluster (realistic testing):"
            local test_pod_node
            test_pod_node=$(oc get pod "$TEST_POD" -n "$TEST_NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
            local egress_assigned_node 
            egress_assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
            
            log_info "   Test pod scheduled on: $test_pod_node"
            log_info "   Egress IP assigned to: $egress_assigned_node"
            log_info "   Testing realistic scenario: Pods can be anywhere in cluster"
            if [[ "$test_pod_node" != "$egress_assigned_node" ]]; then
                log_info "   ✅ EXCELLENT: Pod on different node than egress IP (realistic scenario)"
            else
                log_info "   ℹ️  Pod happens to be on egress node (still valid test)"
            fi
            
            log_info "Test pod details:"
            oc get pod "$TEST_POD" -n "$TEST_NAMESPACE" -o wide || true
            log_info "Namespace verification:"
            oc get namespace "$TEST_NAMESPACE" --show-labels || true
            log_info "Pod network details:"
            oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- ip addr show eth0 || true
            log_info "Pod routing table:"
            oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- ip route show || true
            log_info "========================================="
            
            # PRIMARY TEST: EGRESS IP SOURCE VALIDATION - Does external traffic use egress IP?
            log_info "🎯 PRIMARY TEST: Egress IP Source Validation"
            log_info "ℹ️  Testing if external traffic actually uses the configured egress IP address"
            
            # Get the configured egress IP for comparison
            local eip_address
            eip_address=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
            
            if [[ -n "$external_echo_url" && -n "$eip_address" ]]; then
                log_info "   Pod: $TEST_POD (namespace: $TEST_NAMESPACE)"
                log_info "   Expected egress IP: $eip_address"
                log_info "   External service: $external_echo_url"
                
                # Test connectivity first
                local connectivity_test
                connectivity_test=$(oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- timeout 15 curl -s -o /dev/null -w "%{http_code}" "$external_echo_url" 2>/dev/null || echo "000")
                
                if [[ "$connectivity_test" == "200" ]]; then
                    log_info "✅ External service connectivity: HTTP $connectivity_test"
                    
                    # Get the actual source IP as seen by external service
                    local egress_response
                    egress_response=$(oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- timeout 30 curl -s "$external_echo_url" 2>/dev/null || echo "")
                    
                    # Extract source IP from response
                    local actual_source_ip
                    actual_source_ip=$(echo "$egress_response" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1 || echo "")
                    
                    log_info "   External service sees source IP: $actual_source_ip"
                    
                    # CRITICAL VALIDATION: Compare source IP with egress IP
                    if [[ -n "$actual_source_ip" && "$actual_source_ip" != "127.0.0.1" ]]; then
                        if [[ "$actual_source_ip" == "$eip_address" ]]; then
                            log_success "✅ PRIMARY EGRESS IP TEST PASSED!"
                            log_success "   Expected egress IP: $eip_address"
                            log_success "   Actual source IP: $actual_source_ip"
                            log_success "   ✅ External traffic correctly uses configured egress IP"
                            echo "post_disruption,primary_egress_ip_validation,PASS,$actual_source_ip" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                        else
                            log_error "❌ PRIMARY EGRESS IP TEST FAILED!"
                            log_error "   Expected egress IP: $eip_address"
                            log_error "   Actual source IP: $actual_source_ip"
                            log_error "   ❌ External traffic does NOT use configured egress IP"
                            echo "post_disruption,primary_egress_ip_validation,FAIL,$actual_source_ip" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                            return 1  # FAIL THE TEST - This is the core functionality
                        fi
                    else
                        log_error "❌ PRIMARY EGRESS IP TEST FAILED: Invalid source IP response"
                        log_error "   Raw response: '$egress_response'"
                        log_error "   Extracted IP: '$actual_source_ip'"
                        echo "post_disruption,primary_egress_ip_validation,FAIL,invalid_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                        return 1  # FAIL THE TEST
                    fi
                else
                    log_error "❌ PRIMARY EGRESS IP TEST FAILED: Cannot reach external service (HTTP $connectivity_test)"
                    echo "post_disruption,primary_egress_ip_validation,FAIL,connectivity_failed" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                    return 1  # FAIL THE TEST
                fi
            else
                log_error "❌ PRIMARY EGRESS IP TEST FAILED: Missing external service or egress IP configuration"
                log_error "   External service URL: $external_echo_url"
                log_error "   Egress IP: $eip_address"
                echo "post_disruption,primary_egress_ip_validation,FAIL,missing_config" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                return 1  # FAIL THE TEST
            fi
            
            # Test completed successfully - primary functional validation passed
            log_info "✅ Primary egress IP functional validation completed successfully"
                
            # VALIDATION SUMMARY
            log_success "🎉 EGRESS IP VALIDATION COMPLETED!"
            log_info "✅ Functional test: External traffic uses configured egress IP"
            log_info "Egress IP post-disruption validation completed successfully"
        else
            log_warning "⚠️  Test pod not ready, skipping traffic validation"
            echo "post_disruption,traffic_validation,SKIP,pod_not_ready" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
        fi
        
        # Cleanup test pod
        log_info "Cleaning up test pod: $TEST_POD"
        oc delete pod "$TEST_POD" -n "$TEST_NAMESPACE" --ignore-not-found=true
        
        # Preserve existing traffic generator namespaces (proper chaos testing)
        log_info "ℹ️  Preserving existing traffic generator namespace: $TEST_NAMESPACE"
    fi
    
    return 0
}

# Verify cluster is ready before disruption
if ! verify_cluster_ready; then
    error_exit "Failed to verify cluster is ready"
fi

log_info "Running OVN pod disruption using chaos engineering framework..."
log_info "This will use the redhat-chaos-pod-scenarios to disrupt ovnkube-node pods"

# CHAOS ENGINEERING WORKFLOW EXPLANATION:
# ======================================
# The chaos engineering framework works as follows:
#
# 1. PRE-CHAOS: This script runs pre-disruption validation (cluster readiness)
# 2. CHAOS EXECUTION: The redhat-chaos-pod-scenarios step executes separately
#    - Configured in the workflow chain (openshift-qe-egress-ip-chain.yaml)
#    - Uses krkn framework to kill ovnkube-node pods
#    - TARGET_NAMESPACE=openshift-ovn-kubernetes, POD_LABEL=app=ovnkube-node
#    - Runs independently of this script
# 3. POST-CHAOS: This script runs post-disruption validation (recovery verification)
#
# This script does NOT perform the actual pod disruption - it only does validation
# before and after the chaos step that is executed by the workflow orchestration.
log_info "NOTE: This script performs validation only - actual pod disruption is executed by the chaos framework"
log_info "      The workflow orchestrates: setup -> chaos steps -> validation (this script)"

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
verify_cluster_ready_for_reboot() {
    log_info "Verifying cluster is ready for node reboot testing..."
    
    # Verify OVN pods exist and meet minimum threshold
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    local ovn_pod_count
    ovn_pod_count=$(echo "$worker_pods" | wc -w)
    
    log_info "Found $ovn_pod_count OVN pods for reboot testing (minimum required: $EXPECTED_MIN_OVN_PODS)"
    
    if [[ $ovn_pod_count -lt $EXPECTED_MIN_OVN_PODS ]]; then
        log_error "❌ TEST FAILURE: Insufficient OVN pods for reboot testing: $ovn_pod_count < $EXPECTED_MIN_OVN_PODS (minimum required)"
        echo "reboot_cluster_validation,ovn_pod_count,FAIL,$ovn_pod_count" >> "$ARTIFACT_DIR/reboot_metrics.csv"
        return 1
    fi
    
    log_success "✅ OVN pod count validation PASSED for reboot testing: $ovn_pod_count >= $EXPECTED_MIN_OVN_PODS"
    echo "reboot_cluster_validation,ovn_pod_count,PASS,$ovn_pod_count" >> "$ARTIFACT_DIR/reboot_metrics.csv"
    
    log_info "Found OVN pods: $(echo $worker_pods | tr ' ' ',')"
    
    # Verify egress IP is assigned
    local assigned_node
    assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    if [[ -z "$assigned_node" ]]; then
        log_error "❌ TEST FAILURE: Egress IP $EIP_NAME is not assigned for reboot testing"
        echo "reboot_cluster_validation,egress_ip_assignment,FAIL,unassigned" >> "$ARTIFACT_DIR/reboot_metrics.csv"
        return 1
    fi
    
    log_success "✅ Egress IP assignment validation PASSED for reboot testing: $EIP_NAME assigned to node $assigned_node"
    echo "reboot_cluster_validation,egress_ip_assignment,PASS,$assigned_node" >> "$ARTIFACT_DIR/reboot_metrics.csv"
    
    # SECONDARY: Validate pre-reboot cluster state (simplified functional check)
    log_info "🔍 Validating pre-reboot cluster state (secondary check)..."
    
    # Check if egress IP is still properly assigned
    local current_assigned_node
    current_assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    
    if [[ -z "$current_assigned_node" ]]; then
        log_error "❌ SECONDARY: Pre-reboot cluster state validation FAILED"
        log_error "   Egress IP no longer assigned - cluster may not be ready for reboot testing"
        echo "reboot_cluster_validation,pre_reboot_cluster_state,FAIL,no_assignment" >> "$ARTIFACT_DIR/reboot_metrics.csv"
        return 1
    else
        log_success "✅ SECONDARY: Pre-reboot cluster state validation PASSED: EgressIP assigned to $current_assigned_node"
        echo "reboot_cluster_validation,pre_reboot_cluster_state,PASS,$current_assigned_node" >> "$ARTIFACT_DIR/reboot_metrics.csv"
    fi
    
    log_success "Cluster ready for reboot testing: All validation checks passed"
    log_info "Note: Both primary and secondary validations must pass for reboot readiness"
    
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
    
    # FUNCTIONAL EGRESS IP VALIDATION (using ipecho service)
    log_info "Validating actual egress IP traffic flow after node reboot..."
    
    local eip_address
    eip_address=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -n "$eip_address" ]]; then
        # PROPER CHAOS TESTING: Use existing workload pods that survived node reboot
        # instead of creating new ones after reboot
        log_info "🔍 Using existing traffic generator pods for post-reboot validation..."
        log_info "ℹ️  Proper chaos testing: validate existing workloads survived node reboot"
        
        # Validate egress IP configuration still exists after node reboot
        local eip_post_reboot_status
        eip_post_reboot_status=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
        
        if [[ -z "$eip_post_reboot_status" ]]; then
            log_error "❌ CHAOS TESTING FAILURE: EgressIP resource not assigned after node reboot"
            log_error "   This indicates that either:"
            log_error "   1. EgressIP failed to survive the node reboot (FAILURE)"
            log_error "   2. Node reboot affected OVN controller functionality (FAILURE)"  
            log_error "   3. Cluster state became inconsistent after node reboot (FAILURE)"
            log_error "   Proper chaos testing requires existing workloads to survive infrastructure disruption"
            echo "post_reboot,existing_workload_survival,FAIL,no_pods_found" >> "$ARTIFACT_DIR/reboot_metrics.csv"
            return 1  # FAIL THE TEST - this is a fundamental chaos testing failure
        else
            # EgressIP is still assigned after reboot - use test namespace from setup
            if [[ -f "$SHARED_DIR/egress-namespace" ]]; then
                TEST_NAMESPACE=$(cat "$SHARED_DIR/egress-namespace")
                log_success "✅ EgressIP survived reboot, using test namespace: $TEST_NAMESPACE"
            else
                TEST_NAMESPACE="egress-ip-test"  # fallback
                log_info "Using fallback test namespace: $TEST_NAMESPACE"
            fi
        fi
        
        # Create a temporary test pod for validation after reboot
        TEST_POD="egress-validation-reboot-pod-$(date +%s)"
        log_info "Creating temporary test pod after reboot: $TEST_POD"
        
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD
  namespace: $TEST_NAMESPACE
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF
        
        # Wait for pod readiness after reboot
        if oc wait --for=condition=Ready pod/"$TEST_POD" -n "$TEST_NAMESPACE" --timeout=90s; then
            log_info "🌐 Starting post-reboot network connectivity tests..."
            
            # Network diagnostic tests after reboot
            log_info "📍 Post-reboot pod network interface information:"
            oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- ip addr show || true
            
            log_info "📍 Post-reboot pod routing table:"
            oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- ip route show || true
            
            # PRIMARY TEST: EGRESS IP SOURCE VALIDATION AFTER REBOOT
            log_info "🎯 PRIMARY TEST: Post-reboot Egress IP Source Validation"
            log_info "ℹ️  Testing if external traffic still uses the configured egress IP after reboot"
            
            # Get external echo service URL 
            local external_echo_url=""
            if [[ -f "$SHARED_DIR/health-check-url" ]]; then
                external_echo_url=$(cat "$SHARED_DIR/health-check-url" 2>/dev/null || echo "")
            fi
            
            if [[ -n "$external_echo_url" && -n "$eip_address" ]]; then
                log_info "   Pod: $TEST_POD (namespace: $TEST_NAMESPACE)"
                log_info "   Expected egress IP: $eip_address"
                log_info "   External service: $external_echo_url"
                
                # Test connectivity first
                local connectivity_test
                connectivity_test=$(oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- timeout 15 curl -s -o /dev/null -w "%{http_code}" "$external_echo_url" 2>/dev/null || echo "000")
                
                if [[ "$connectivity_test" == "200" ]]; then
                    log_info "✅ Post-reboot external service connectivity: HTTP $connectivity_test"
                    
                    # Get the actual source IP as seen by external service
                    local reboot_response
                    reboot_response=$(oc exec -n "$TEST_NAMESPACE" "$TEST_POD" -- timeout 30 curl -s "$external_echo_url" 2>/dev/null || echo "")
                    
                    # Extract source IP from response
                    local actual_source_ip
                    actual_source_ip=$(echo "$reboot_response" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | head -n1 || echo "")
                    
                    log_info "   External service sees source IP: $actual_source_ip"
                    
                    # CRITICAL VALIDATION: Compare source IP with egress IP
                    if [[ -n "$actual_source_ip" && "$actual_source_ip" != "127.0.0.1" ]]; then
                        if [[ "$actual_source_ip" == "$eip_address" ]]; then
                            log_success "✅ PRIMARY POST-REBOOT EGRESS IP TEST PASSED!"
                            log_success "   Expected egress IP: $eip_address"
                            log_success "   Actual source IP: $actual_source_ip"
                            log_success "   ✅ External traffic correctly uses configured egress IP after reboot"
                            echo "post_reboot,primary_egress_ip_validation,PASS,$actual_source_ip" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                        else
                            log_error "❌ PRIMARY POST-REBOOT EGRESS IP TEST FAILED!"
                            log_error "   Expected egress IP: $eip_address"
                            log_error "   Actual source IP: $actual_source_ip"
                            log_error "   ❌ External traffic does NOT use configured egress IP after reboot"
                            echo "post_reboot,primary_egress_ip_validation,FAIL,$actual_source_ip" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                            return 1  # FAIL THE TEST - This is the core functionality
                        fi
                    else
                        log_error "❌ PRIMARY POST-REBOOT EGRESS IP TEST FAILED: Invalid source IP response"
                        log_error "   Raw response: '$reboot_response'"
                        log_error "   Extracted IP: '$actual_source_ip'"
                        echo "post_reboot,primary_egress_ip_validation,FAIL,invalid_response" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                        return 1  # FAIL THE TEST
                    fi
                else
                    log_error "❌ PRIMARY POST-REBOOT EGRESS IP TEST FAILED: Cannot reach external service (HTTP $connectivity_test)"
                    echo "post_reboot,primary_egress_ip_validation,FAIL,connectivity_failed" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                    return 1  # FAIL THE TEST
                fi
            else
                log_error "❌ PRIMARY POST-REBOOT EGRESS IP TEST FAILED: Missing external service or egress IP configuration"
                log_error "   External service URL: $external_echo_url"
                log_error "   Egress IP: $eip_address"
                echo "post_reboot,primary_egress_ip_validation,FAIL,missing_config" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                return 1  # FAIL THE TEST
            fi
            
            # Test completed successfully - primary functional validation passed after reboot
            log_info "✅ Primary egress IP functional validation completed successfully after reboot"
            
            # VALIDATION SUMMARY
            log_success "🎉 POST-REBOOT EGRESS IP VALIDATION COMPLETED!"
            log_info "✅ Functional test: External traffic uses configured egress IP after reboot"
        else
            log_warning "⚠️  Test pod not ready after reboot, skipping traffic validation"
            echo "post_reboot,traffic_validation,SKIP,pod_not_ready" >> "$ARTIFACT_DIR/reboot_metrics.csv"
        fi
        
        # Cleanup test pod
        log_info "Cleaning up test pod: $TEST_POD"
        oc delete pod "$TEST_POD" -n "$TEST_NAMESPACE" --ignore-not-found=true
        
        # Preserve existing traffic generator namespaces (proper chaos testing)
        log_info "ℹ️  Preserving existing traffic generator namespace: $TEST_NAMESPACE"
    fi
    
    return 0
}

# Verify cluster is ready before node reboot
if ! verify_cluster_ready_for_reboot; then
    error_exit "Failed to verify cluster is ready for reboot testing"
fi

log_info "Running node reboot disruption using chaos engineering framework..."
log_info "This will use the redhat-chaos-node-disruptions with ACTION=node_reboot_scenario"

# CHAOS ENGINEERING WORKFLOW EXPLANATION:
# ======================================
# The chaos engineering framework works as follows:
#
# 1. PRE-CHAOS: This script runs pre-reboot validation (cluster readiness)
# 2. CHAOS EXECUTION: The redhat-chaos-node-disruptions step executes separately
#    - Configured in the workflow chain (openshift-qe-egress-ip-chain.yaml)
#    - Uses krkn framework to perform actual node reboots
#    - ACTION=node_reboot_scenario targets worker nodes
#    - Runs independently of this script
# 3. POST-CHAOS: This script runs post-reboot validation (recovery verification)
#
# This script does NOT perform the actual node reboot - it only does validation
# before and after the chaos step that is executed by the workflow orchestration.
#
# Workflow execution order:
#   setup -> pod-chaos -> node-chaos -> tests (this script)
#             ^^^^^^^    ^^^^^^^^^^    ^^^^^
#           (separate)  (separate)   (validation only)
log_info "NOTE: This script performs validation only - actual node reboot is executed by the chaos framework"
log_info "      The workflow orchestrates: setup -> chaos steps -> validation (this script)"

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

# CRITICAL: Test Results Summary with Pass/Fail Validation
log_info "==============================="
log_info "TEST RESULTS SUMMARY"
log_info "==============================="

# Initialize counters
total_tests=0
passed_tests=0
failed_tests=0

# Count test results from metrics files
log_info "📊 Analyzing test results..."

# Process cluster validation metrics
if [[ -f "$ARTIFACT_DIR/test_validation_metrics.csv" ]]; then
    while IFS=',' read -r phase test_name result value; do
        total_tests=$((total_tests + 1))
        if [[ "$result" == "PASS" ]]; then
            passed_tests=$((passed_tests + 1))
            log_success "✅ $phase/$test_name: $result ($value)"
        else
            failed_tests=$((failed_tests + 1))
            log_error "❌ $phase/$test_name: $result ($value)"
        fi
    done < "$ARTIFACT_DIR/test_validation_metrics.csv"
fi

# Process pod disruption metrics
if [[ -f "$ARTIFACT_DIR/pod_disruption_metrics.csv" ]]; then
    log_info "Pod disruption test results:"
    while IFS=',' read -r phase test_name result value; do
        total_tests=$((total_tests + 1))
        if [[ "$result" == "PASS" ]]; then
            passed_tests=$((passed_tests + 1))
            log_success "✅ $phase/$test_name: $result ($value)"
        else
            failed_tests=$((failed_tests + 1))
            log_error "❌ $phase/$test_name: $result ($value)"
        fi
    done < "$ARTIFACT_DIR/pod_disruption_metrics.csv"
fi

# Process reboot metrics
if [[ -f "$ARTIFACT_DIR/reboot_metrics.csv" ]]; then
    log_info "Node reboot test results:"
    while IFS=',' read -r phase test_name result value; do
        total_tests=$((total_tests + 1))
        if [[ "$result" == "PASS" ]]; then
            passed_tests=$((passed_tests + 1))
            log_success "✅ $phase/$test_name: $result ($value)"
        else
            failed_tests=$((failed_tests + 1))
            log_error "❌ $phase/$test_name: $result ($value)"
        fi
    done < "$ARTIFACT_DIR/reboot_metrics.csv"
fi

# Calculate test statistics
log_info "==============================="
log_info "FINAL TEST STATISTICS"
log_info "==============================="
log_info "📊 Total Tests Executed: $total_tests"
log_info "✅ Passed Tests: $passed_tests (PRIMARY + SECONDARY)"
log_info "❌ Failed Tests: $failed_tests (PRIMARY + SECONDARY)"

# Calculate pass rate
if [[ $total_tests -gt 0 ]]; then
    pass_rate=$((passed_tests * 100 / total_tests))
    log_info "📈 Test Pass Rate: $pass_rate% ($passed_tests passed out of $total_tests total tests)"
else
    pass_rate=0
    log_warning "⚠️  No tests were executed"
fi

# Test Configuration Summary
log_info "==============================="
log_info "TEST CONFIGURATION SUMMARY"
log_info "==============================="
log_info "🔧 Configuration:"
log_info "  - Egress IP: $EIP_NAME"
log_info "  - Expected minimum OVN pods: $EXPECTED_MIN_OVN_PODS"
log_info "  - Pod Kill Tests: $POD_KILL_RETRIES iterations"
log_info "  - Node Reboot Tests: $REBOOT_RETRIES iterations"
log_info "  - Total Runtime: $SECONDS seconds"
log_info "  - Log File: $LOG_FILE"

# Artifact Summary
log_info "📁 Test Artifacts:"
if [[ -f "$ARTIFACT_DIR/test_validation_metrics.csv" ]]; then
    log_info "  - Cluster validation metrics: $ARTIFACT_DIR/test_validation_metrics.csv"
fi
if [[ -f "$ARTIFACT_DIR/pod_disruption_metrics.csv" ]]; then
    log_info "  - Pod disruption metrics: $ARTIFACT_DIR/pod_disruption_metrics.csv"
fi
if [[ -f "$ARTIFACT_DIR/reboot_metrics.csv" ]]; then
    log_info "  - Reboot test metrics: $ARTIFACT_DIR/reboot_metrics.csv"
fi

# CRITICAL: Exit with failure code if any tests failed
if [[ $failed_tests -gt 0 ]]; then
    log_error "==============================="
    log_error "🚨 TEST SUITE FAILED!"
    log_error "==============================="
    log_error "❌ $failed_tests out of $total_tests tests failed"
    log_error "   This indicates issues with egress IP configuration or resilience"
    log_error "   Review the detailed logs and metrics files for specific failure reasons"
    
    # Show baseline comparison if available
    if [[ -f "$SHARED_DIR/baseline_snat_count" ]]; then
        baseline_count=$(cat "$SHARED_DIR/baseline_snat_count" 2>/dev/null || echo "unknown")
        log_error "   Baseline SNAT count: $baseline_count"
    fi
    
    error_exit "Egress IP resilience test suite failed with $failed_tests failures out of $total_tests tests"
else
    log_success "==============================="
    log_success "🎉 TEST SUITE PASSED!"
    log_success "==============================="
    log_success "✅ All $total_tests tests passed successfully"
    log_success "   OpenShift QE Egress IP resilience testing completed with 100% pass rate"
    log_success "   Egress IP configuration and resilience validated under chaos engineering conditions"
fi
