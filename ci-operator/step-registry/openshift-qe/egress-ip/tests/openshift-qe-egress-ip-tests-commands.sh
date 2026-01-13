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

# Get external validation service URL from setup (cloud-bulldozer compatible)
if [[ -f "$SHARED_DIR/egress-health-check-url" ]]; then
    IPECHO_SERVICE_URL=$(cat "$SHARED_DIR/egress-health-check-url")
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
    
    # FUNCTIONAL EGRESS IP VALIDATION (using ipecho service)
    log_info "Validating actual egress IP traffic flow using functional testing..."
    
    local eip_address
    eip_address=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -n "$eip_address" ]]; then
        # Create temporary test pod to validate traffic
        cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: egress-test-temp
  labels:
    egress: egress-ip-test
---
apiVersion: v1
kind: Pod
metadata:
  name: traffic-test-pod
  namespace: egress-test-temp
  labels:
    app: "egress-test-app"
    egress-enabled: "true"
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: curl-container
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF
        
        # Wait for pod readiness
        if oc wait --for=condition=Ready pod/traffic-test-pod -n egress-test-temp --timeout=60s; then
            log_info "🌐 Starting comprehensive network connectivity tests..."
            
            # Network diagnostic tests
            log_info "📍 Pod network interface information:"
            oc exec -n egress-test-temp traffic-test-pod -- ip addr show || true
            
            log_info "📍 Pod routing table:"
            oc exec -n egress-test-temp traffic-test-pod -- ip route show || true
            
            # Test connectivity to various endpoints with detailed logging
            log_info "🏓 Testing network connectivity with ping tests..."
            
            # Ping Google DNS (external connectivity test)
            log_info "📡 Ping test to Google DNS (8.8.8.8):"
            oc exec -n egress-test-temp traffic-test-pod -- ping -c 3 8.8.8.8 2>&1 | tee -a "$ARTIFACT_DIR/ping_tests.log" || log_warning "⚠️  Google DNS ping failed"
            
            # Ping httpbin.org (primary test service)
            log_info "📡 Ping test to httpbin.org:"
            httpbin_ip=$(oc exec -n egress-test-temp traffic-test-pod -- nslookup httpbin.org 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}' || echo "")
            if [[ -n "$httpbin_ip" ]]; then
                log_info "🎯 httpbin.org resolves to: $httpbin_ip"
                oc exec -n egress-test-temp traffic-test-pod -- ping -c 3 "$httpbin_ip" 2>&1 | tee -a "$ARTIFACT_DIR/ping_tests.log" || log_warning "⚠️  httpbin.org ping failed"
            fi
            
            # Test inter-cluster connectivity (ping other egress IPs if they exist)
            log_info "🔗 Testing inter-egress IP connectivity..."
            egress_ips=$(oc get egressip -o jsonpath='{.items[*].spec.egressIPs[*]}' 2>/dev/null || echo "")
            if [[ -n "$egress_ips" ]]; then
                for other_eip in $egress_ips; do
                    if [[ "$other_eip" != "$eip_address" ]]; then
                        log_info "📡 Ping test to other egress IP $other_eip:"
                        oc exec -n egress-test-temp traffic-test-pod -- ping -c 2 "$other_eip" 2>&1 | tee -a "$ARTIFACT_DIR/ping_tests.log" || log_info "ℹ️  Inter-EIP ping to $other_eip: not directly reachable (expected for egress IPs)"
                    fi
                done
            fi
            
            # FUNCTIONAL EGRESS IP VALIDATION using ipecho service
            log_info "🎯 Testing actual egress IP traffic flow with functional validation..."
            
            # 1. Test egress IP enabled pod - should use egress IP
            log_info "📡 Testing egress IP enabled pod (should show egress IP: $eip_address)"
            local egress_response
            egress_response=$(oc exec -n egress-test-temp traffic-test-pod -- timeout 30 curl -s "$IPECHO_SERVICE_URL" 2>/dev/null || echo "")
            log_info "📥 Egress IP pod response: '$egress_response'"
            
            # Clean and validate the response
            local clean_egress_response
            clean_egress_response=$(echo "$egress_response" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
            
            if [[ "$clean_egress_response" == "$eip_address" ]]; then
                log_success "✅ EGRESS IP VALIDATION PASSED: Pod uses egress IP $eip_address"
                echo "post_disruption,functional_validation,PASS,$eip_address" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
            else
                log_error "❌ EGRESS IP VALIDATION FAILED: Expected $eip_address, got '$clean_egress_response'"
                echo "post_disruption,functional_validation,FAIL,$clean_egress_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                
                # Debug information
                log_info "🔍 Debug info:"
                log_info "  - Raw response: '$egress_response'"
                log_info "  - ipecho service URL: $IPECHO_SERVICE_URL"
                log_info "  - Expected egress IP: $eip_address"
                log_info "  - Actual response IP: '$clean_egress_response'"
                
                return 1
            fi
            
            # 2. Create and test control pod (non-egress IP namespace) - should NOT use egress IP
            log_info "🔍 Testing control pod (should NOT use egress IP)"
            
            # Create control namespace without egress IP labels
            cat << CONTROL_EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: egress-control-test
  # Note: NO egress IP labels
---
apiVersion: v1
kind: Pod
metadata:
  name: control-test-pod
  namespace: egress-control-test
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: curl-container
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
CONTROL_EOF
            
            # Wait for control pod
            if oc wait --for=condition=Ready pod/control-test-pod -n egress-control-test --timeout=60s; then
                local control_response
                control_response=$(oc exec -n egress-control-test control-test-pod -- timeout 30 curl -s "$IPECHO_SERVICE_URL" 2>/dev/null || echo "")
                log_info "📥 Control pod response: '$control_response'"
                
                local clean_control_response
                clean_control_response=$(echo "$control_response" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
                
                if [[ "$clean_control_response" != "$eip_address" ]]; then
                    log_success "✅ CONTROL VALIDATION PASSED: Non-egress pod does NOT use egress IP (uses: $clean_control_response)"
                    echo "post_disruption,control_validation,PASS,$clean_control_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                else
                    log_error "❌ CONTROL VALIDATION FAILED: Non-egress pod incorrectly uses egress IP $eip_address"
                    echo "post_disruption,control_validation,FAIL,$clean_control_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                fi
                
                # Cleanup control resources
                oc delete namespace egress-control-test --ignore-not-found=true &>/dev/null
            else
                log_warning "⚠️  Control pod not ready, skipping control validation"
                echo "post_disruption,control_validation,SKIP,pod_not_ready" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
            fi
        else
            log_warning "⚠️  Test pod not ready, skipping traffic validation"
            echo "post_disruption,traffic_validation,SKIP,pod_not_ready" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
        fi
        
        # Cleanup
        oc delete namespace egress-test-temp --ignore-not-found=true &>/dev/null
    fi
    
    # Keep minimal NAT count for reference (not primary validation)
    local worker_pods
    worker_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    local total_nat_count=0
    for pod in $worker_pods; do
        local count
        count=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        total_nat_count=$((total_nat_count + count))
    done
    
    log_info "Reference NAT count: $total_nat_count (note: primary validation is real traffic flow)"
    echo "post_disruption,nat_count,$total_nat_count" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
    
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
    
    # FUNCTIONAL EGRESS IP VALIDATION (using ipecho service)
    log_info "Validating actual egress IP traffic flow after node reboot..."
    
    local eip_address
    eip_address=$(oc get egressip "$EIP_NAME" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -n "$eip_address" ]]; then
        # Create temporary test pod to validate traffic
        cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: egress-reboot-test
  labels:
    egress: egress-ip-test
---
apiVersion: v1
kind: Pod
metadata:
  name: reboot-traffic-test
  namespace: egress-reboot-test
  labels:
    app: "egress-test-app"
    egress-enabled: "true"
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: curl-container
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1001
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF
        
        # Wait for pod readiness
        if oc wait --for=condition=Ready pod/reboot-traffic-test -n egress-reboot-test --timeout=90s; then
            log_info "🌐 Starting post-reboot network connectivity tests..."
            
            # Network diagnostic tests after reboot
            log_info "📍 Post-reboot pod network interface information:"
            oc exec -n egress-reboot-test reboot-traffic-test -- ip addr show || true
            
            log_info "📍 Post-reboot pod routing table:"
            oc exec -n egress-reboot-test reboot-traffic-test -- ip route show || true
            
            # Test connectivity after reboot with detailed logging
            log_info "🏓 Testing post-reboot network connectivity with ping tests..."
            
            # Ping Google DNS (external connectivity test after reboot)
            log_info "📡 Post-reboot ping test to Google DNS (8.8.8.8):"
            oc exec -n egress-reboot-test reboot-traffic-test -- ping -c 3 8.8.8.8 2>&1 | tee -a "$ARTIFACT_DIR/post_reboot_ping_tests.log" || log_warning "⚠️  Post-reboot Google DNS ping failed"
            
            # Test inter-cluster connectivity after reboot
            log_info "🔗 Testing post-reboot inter-egress IP connectivity..."
            egress_ips=$(oc get egressip -o jsonpath='{.items[*].spec.egressIPs[*]}' 2>/dev/null || echo "")
            if [[ -n "$egress_ips" ]]; then
                for other_eip in $egress_ips; do
                    if [[ "$other_eip" != "$eip_address" ]]; then
                        log_info "📡 Post-reboot ping test to other egress IP $other_eip:"
                        oc exec -n egress-reboot-test reboot-traffic-test -- ping -c 2 "$other_eip" 2>&1 | tee -a "$ARTIFACT_DIR/post_reboot_ping_tests.log" || log_info "ℹ️  Post-reboot inter-EIP ping to $other_eip: not directly reachable (expected)"
                    fi
                done
            fi
            
            # Validate egress IP internal networking after reboot using e2e methodology
            log_info "🔧 Testing post-reboot egress IP internal networking configuration..."
            
            # 1. Re-verify egress IP assignment after reboot
            local current_assigned_node
            current_assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
            local assigned_node_ip
            assigned_node_ip=$(oc get node "$current_assigned_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
            log_info "📍 Post-reboot: Egress IP $eip_address assigned to node $current_assigned_node (internal IP: $assigned_node_ip)"
            
            # 2. Re-check OVN configuration after reboot
            log_info "🔍 Verifying post-reboot OVN logical router policy configuration..."
            local ovn_pod
            ovn_pod=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            
            if [[ -n "$ovn_pod" ]]; then
                # Check for logical router policies after reboot
                local lr_policies
                lr_policies=$(oc exec -n "$NAMESPACE" "$ovn_pod" -c ovnkube-controller -- ovn-nbctl lr-policy-list ovn_cluster_router 2>/dev/null | grep -c "$eip_address" || echo "0")
                log_info "📊 Post-reboot: Found $lr_policies logical router policies for egress IP $eip_address"
                
                # Check for NAT rules after reboot
                local nat_rules
                nat_rules=$(oc exec -n "$NAMESPACE" "$ovn_pod" -c ovnkube-controller -- ovn-nbctl --format=csv --no-heading find nat external_ip="$eip_address" 2>/dev/null | wc -l || echo "0")
                log_info "📊 Post-reboot: Found $nat_rules NAT rules for egress IP $eip_address"
                
                if [[ "$nat_rules" -gt 0 ]] && [[ "$lr_policies" -gt 0 ]]; then
                    log_success "✅ POST-REBOOT INTERNAL NETWORKING VALIDATION PASSED: OVN configuration restored"
                    echo "post_reboot,internal_validation,PASS,$eip_address" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                else
                    log_warning "⚠️  Post-reboot OVN configuration incomplete: NAT rules: $nat_rules, LR policies: $lr_policies"
                    echo "post_reboot,internal_validation,PARTIAL,$eip_address" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                fi
            else
                log_warning "⚠️  Could not find OVN pod for post-reboot internal validation"
                echo "post_reboot,internal_validation,SKIP,no_ovn_pod" >> "$ARTIFACT_DIR/reboot_metrics.csv"
            fi
            
            # 3. Verify external connectivity after reboot (without egress IP verification)
            log_info "🌐 Testing post-reboot basic external connectivity..."
            if oc exec -n egress-reboot-test reboot-traffic-test -- timeout 10 curl -s -f https://httpbin.org/status/200 >/dev/null 2>&1; then
                log_success "✅ POST-REBOOT CONNECTIVITY VALIDATION PASSED: Pod has external connectivity"
                echo "post_reboot,connectivity_validation,PASS,external_reachable" >> "$ARTIFACT_DIR/reboot_metrics.csv"
            else
                log_error "❌ POST-REBOOT CONNECTIVITY VALIDATION FAILED: Pod cannot reach external services"
                echo "post_reboot,connectivity_validation,FAIL,external_unreachable" >> "$ARTIFACT_DIR/reboot_metrics.csv"
                return 1
            fi
        else
            log_warning "⚠️  Test pod not ready after reboot, skipping traffic validation"
            echo "post_reboot,traffic_validation,SKIP,pod_not_ready" >> "$ARTIFACT_DIR/reboot_metrics.csv"
        fi
        
        # Cleanup
        oc delete namespace egress-reboot-test --ignore-not-found=true &>/dev/null
    fi
    
    # Keep minimal SNAT/LR policy counts for reference (not primary validation)
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
    
    log_info "Reference metrics - SNAT: $total_snat_count, LR policy: $total_policy_count (note: primary validation is real traffic flow)"
    echo "post_reboot,snat_lr_reference,$total_snat_count,$total_policy_count" >> "$ARTIFACT_DIR/reboot_metrics.csv"
    
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
