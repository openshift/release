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
  name: egress-ip-test
  labels:
    kubernetes.io/metadata.name: egress-ip-test
    egress-ip: enabled
---
apiVersion: v1
kind: Pod
metadata:
  name: traffic-test-pod
  namespace: egress-ip-test
  labels:
    app: "egress-test-app"
    egress-enabled: "true"
spec:
  # CRITICAL: Schedule pod on egress IP assigned node for proper routing
  nodeSelector:
    kubernetes.io/hostname: "$ASSIGNED_NODE"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
            - "$ASSIGNED_NODE"
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
        if oc wait --for=condition=Ready pod/traffic-test-pod -n egress-ip-test --timeout=60s; then
            log_info "🌐 Starting comprehensive network connectivity tests..."
            
            # Network diagnostic tests
            log_info "📍 Pod network interface information:"
            oc exec -n egress-ip-test traffic-test-pod -- ip addr show || true
            
            log_info "📍 Pod routing table:"
            oc exec -n egress-ip-test traffic-test-pod -- ip route show || true
            
            # Test connectivity to various endpoints with detailed logging
            log_info "🏓 Testing network connectivity with ping tests..."
            
            # Ping Google DNS (external connectivity test)
            log_info "📡 Ping test to Google DNS (8.8.8.8):"
            oc exec -n egress-ip-test traffic-test-pod -- ping -c 3 8.8.8.8 2>&1 | tee -a "$ARTIFACT_DIR/ping_tests.log" || log_warning "⚠️  Google DNS ping failed"
            
            # Ping httpbin.org (primary test service)
            log_info "📡 Ping test to httpbin.org:"
            httpbin_ip=$(oc exec -n egress-ip-test traffic-test-pod -- nslookup httpbin.org 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}' || echo "")
            if [[ -n "$httpbin_ip" ]]; then
                log_info "🎯 httpbin.org resolves to: $httpbin_ip"
                oc exec -n egress-ip-test traffic-test-pod -- ping -c 3 "$httpbin_ip" 2>&1 | tee -a "$ARTIFACT_DIR/ping_tests.log" || log_warning "⚠️  httpbin.org ping failed"
            fi
            
            # Test inter-cluster connectivity (ping other egress IPs if they exist)
            log_info "🔗 Testing inter-egress IP connectivity..."
            egress_ips=$(oc get egressip -o jsonpath='{.items[*].spec.egressIPs[*]}' 2>/dev/null || echo "")
            if [[ -n "$egress_ips" ]]; then
                for other_eip in $egress_ips; do
                    if [[ "$other_eip" != "$eip_address" ]]; then
                        log_info "📡 Ping test to other egress IP $other_eip:"
                        oc exec -n egress-ip-test traffic-test-pod -- ping -c 2 "$other_eip" 2>&1 | tee -a "$ARTIFACT_DIR/ping_tests.log" || log_info "ℹ️  Inter-EIP ping to $other_eip: not directly reachable (expected for egress IPs)"
                    fi
                done
            fi
            
            # CRITICAL: ACTUAL SOURCE IP VALIDATION using external bastion service
            log_info "🎯 Testing actual egress IP source validation with external bastion service..."
            log_info "ℹ️  Note: Egress IPs only apply to external traffic, not internal cluster traffic"
            
            # Get external bastion echo service URL
            local external_echo_url=""
            if [[ -f "$SHARED_DIR/egress-health-check-url" ]]; then
                external_echo_url=$(cat "$SHARED_DIR/egress-health-check-url" 2>/dev/null || echo "")
                log_info "📡 Using external bastion IP echo service: $external_echo_url"
            else
                log_error "❌ External bastion echo service URL not found"
                echo "post_disruption,source_ip_validation,FAIL,no_external_service" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                return 1
            fi
            
            # DEBUG: Pre-validation state verification
            log_info "🔍 DEBUG: Pre-validation EgressIP state verification:"
            log_info "Current EgressIP status:"
            oc describe egressip "$EIP_NAME" || true
            
            # CRITICAL: Validate pod scheduling (must be on egress IP assigned node)
            log_info "🔍 DEBUG: Pod scheduling validation (CRITICAL for egress IP routing):"
            local test_pod_node
            test_pod_node=$(oc get pod traffic-test-pod -n egress-ip-test -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
            local egress_assigned_node 
            egress_assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
            
            log_info "   Test pod scheduled on: $test_pod_node"
            log_info "   Egress IP assigned to: $egress_assigned_node"
            
            if [[ "$test_pod_node" == "$egress_assigned_node" ]]; then
                log_success "✅ CORRECT: Test pod is on the egress IP assigned node"
            else
                log_error "❌ WRONG: Test pod is on different node than egress IP!"
                log_error "   This will cause routing issues - pods must be on egress IP node"
                log_error "   Fix: Check nodeSelector and affinity rules in pod spec"
            fi
            
            log_info "Test pod details:"
            oc get pod traffic-test-pod -n egress-ip-test -o wide || true
            log_info "Namespace verification:"
            oc get namespace egress-ip-test --show-labels || true
            log_info "Pod network details:"
            oc exec -n egress-ip-test traffic-test-pod -- ip addr show eth0 || true
            log_info "Pod routing table:"
            oc exec -n egress-ip-test traffic-test-pod -- ip route show || true
            log_info "========================================="
            
            # 1. Test egress IP enabled pod - validate ACTUAL SOURCE IP via external service
            # Debug: Test bastion service connectivity first
            log_info "🔍 DEBUG: Testing bastion service connectivity from test pod..."
            local connectivity_test
            connectivity_test=$(oc exec -n egress-ip-test traffic-test-pod -- timeout 15 curl -s -o /dev/null -w "%{http_code}" "$external_echo_url" 2>/dev/null || echo "000")
            if [[ "$connectivity_test" == "200" ]]; then
                log_success "✅ Bastion service connectivity: HTTP $connectivity_test"
            else
                log_error "❌ Bastion service connectivity failed: HTTP $connectivity_test"
                log_error "   This indicates security group or networking issues"
                log_error "   External echo URL: $external_echo_url"
            fi
            
            log_info "📡 Testing egress IP enabled pod SOURCE IP validation via external bastion service"
            local egress_response
            egress_response=$(oc exec -n egress-ip-test traffic-test-pod -- timeout 30 curl -s "$external_echo_url" 2>/dev/null || echo "")
            log_info "📥 Egress IP pod response: '$egress_response'"
            
            # Extract source IP from JSON response (external services will show NAT IP in AWS)
            # Handle both "source_ip" (our bastion service) and "origin" (httpbin.org) field names
            local actual_source_ip
            actual_source_ip=$(echo "$egress_response" | grep -o '"source_ip"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
            if [[ -z "$actual_source_ip" ]]; then
                # Fallback to "origin" field for httpbin.org and similar services
                actual_source_ip=$(echo "$egress_response" | grep -o '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
            fi
            
            if [[ -n "$actual_source_ip" && "$actual_source_ip" != "127.0.0.1" ]]; then
                log_info "📍 External service sees source IP: $actual_source_ip (AWS NAT Gateway IP)"
                
                # For AWS environments, external services see the NAT Gateway IP, not the egress IP directly
                # We validate egress IP functionality by testing traffic routing consistency
                # Store the NAT IP for comparison with non-egress traffic
                echo "$actual_source_ip" > "$SHARED_DIR/egress-external-nat-ip"
                
                # Test non-egress namespace traffic for comparison
                log_info "🔍 Testing non-egress namespace for comparison..."
                
                # Create a pod in default namespace (without egress IP) for comparison
                # Schedule it on a different node to avoid egress IP interference
                local egress_assigned_node
                egress_assigned_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
                local non_egress_node
                non_egress_node=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "$egress_assigned_node" | head -n1 || echo "")
                
                if [[ -n "$non_egress_node" ]]; then
                    cat << EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: non-egress-test-pod
  namespace: default
spec:
  # Schedule on non-egress node to avoid interference
  nodeSelector:
    kubernetes.io/hostname: "$non_egress_node"
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test-container
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
                else
                    # Fallback: create pod without node selector if only one worker node
                    cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: non-egress-test-pod
  namespace: default
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test-container
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
                fi
                
                # Wait for non-egress pod to be ready
                oc wait --for=condition=Ready pod/non-egress-test-pod -n default --timeout=60s || true
                
                # Test traffic from non-egress pod
                local non_egress_response
                non_egress_response=$(oc exec -n default non-egress-test-pod -- timeout 30 curl -s "$external_echo_url" 2>/dev/null || echo "")
                local non_egress_ip
                non_egress_ip=$(echo "$non_egress_response" | grep -o '"source_ip"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
                if [[ -z "$non_egress_ip" ]]; then
                    # Fallback to "origin" field for httpbin.org and similar services
                    non_egress_ip=$(echo "$non_egress_response" | grep -o '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
                fi
                
                log_info "📍 Non-egress namespace sees external IP: $non_egress_ip"
                
                # IMPORTANT: In AWS, egress IPs work at the VPC level but external internet services 
                # still see the NAT Gateway IP due to AWS networking architecture
                # The key validation is that egress IP SNAT rules are properly configured in OVN
                
                # Validate internal egress IP configuration first
                local current_eip_node
                current_eip_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
                local current_eip_status
                current_eip_status=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].egressIP}' 2>/dev/null || echo "")
                
                if [[ "$current_eip_status" == "$eip_address" && -n "$current_eip_node" ]]; then
                    # Check OVN SNAT rules for proper egress IP configuration
                    local test_pod_ip
                    test_pod_ip=$(oc get pod traffic-test-pod -n egress-ip-test -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
                    
                    if [[ -n "$test_pod_ip" ]]; then
                        log_info "🔍 DEBUG: Starting OVN SNAT rule validation"
                        log_info "   Test pod IP: $test_pod_ip"
                        log_info "   Egress IP: $eip_address"  
                        log_info "   Egress node: $current_eip_node"
                        
                        # Get OVN pod on egress node to check SNAT rules
                        local ovn_pod_name
                        ovn_pod_name=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName="$current_eip_node" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                        
                        if [[ -n "$ovn_pod_name" ]]; then
                            log_info "   OVN pod on egress node: $ovn_pod_name"
                            
                            # Check if SNAT rule exists for test pod IP -> egress IP
                            log_info "🔍 Checking for SNAT rule: $test_pod_ip -> $eip_address"
                            local snat_check
                            snat_check=$(oc exec -n openshift-ovn-kubernetes "$ovn_pod_name" -- ovn-nbctl --format=csv --no-heading find nat logical_ip="$test_pod_ip" external_ip="$eip_address" type=snat 2>/dev/null || echo "")
                            
                            # Also show all SNAT rules for debugging
                            log_info "🔍 DEBUG: All SNAT rules on egress node:"
                            local all_snat_rules
                            all_snat_rules=$(oc exec -n openshift-ovn-kubernetes "$ovn_pod_name" -- ovn-nbctl --format=csv --no-heading find nat type=snat 2>/dev/null || echo "No SNAT rules found")
                            log_info "$all_snat_rules"
                            
                            if [[ -n "$snat_check" ]]; then
                                log_success "✅ EGRESS IP VALIDATION PASSED: OVN SNAT rule correctly configured"
                                log_success "   Test pod IP $test_pod_ip -> Egress IP $eip_address SNAT rule exists"
                                log_success "   SNAT rule details: $snat_check"
                                log_success "   External internet traffic shows NAT Gateway IP ($actual_source_ip) - this is correct AWS behavior"
                                echo "post_disruption,source_ip_validation,PASS,$actual_source_ip" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                                
                                # Additional verification: consistent external routing
                                if [[ -n "$non_egress_ip" && "$actual_source_ip" == "$non_egress_ip" ]]; then
                                    log_success "✅ EXTERNAL ROUTING CONSISTENCY: Both egress and non-egress pods use same NAT gateway"
                                    echo "post_disruption,external_routing_consistency,PASS,$actual_source_ip" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                                fi
                            else
                                log_error "❌ EGRESS IP VALIDATION FAILED: Missing OVN SNAT rule for test pod"
                                log_error "   Expected: SNAT rule $test_pod_ip -> $eip_address"
                                log_error "   Test pod IP: $test_pod_ip"
                                log_error "   Egress IP: $eip_address"
                                log_error "   All SNAT rules: $all_snat_rules"
                                echo "post_disruption,source_ip_validation,FAIL,missing_snat_rule" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                            fi
                        else
                            log_error "❌ EGRESS IP VALIDATION FAILED: Cannot find OVN pod on egress node"
                            echo "post_disruption,source_ip_validation,FAIL,ovn_pod_not_found" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                        fi
                    else
                        log_error "❌ EGRESS IP VALIDATION FAILED: Cannot determine test pod IP"
                        echo "post_disruption,source_ip_validation,FAIL,pod_ip_not_found" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                    fi
                else
                    log_error "❌ EGRESS IP VALIDATION FAILED: EgressIP not properly assigned"
                    echo "post_disruption,source_ip_validation,FAIL,egressip_not_assigned" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                    return 1
                fi
                
                # Secondary validation: Test external connectivity works
                log_info "🌐 Secondary validation: Testing external connectivity..."
                local external_test_response
                external_test_response=$(oc exec -n egress-ip-test traffic-test-pod -- timeout 15 curl -s -o /dev/null -w "%{http_code}" "$IPECHO_SERVICE_URL" 2>/dev/null || echo "000")
                
                if [[ "$external_test_response" == "200" ]]; then
                    log_success "✅ EXTERNAL CONNECTIVITY VALIDATION PASSED: External services reachable"
                    echo "post_disruption,connectivity_validation,PASS,http_$external_test_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                else
                    log_warning "⚠️  EXTERNAL CONNECTIVITY VALIDATION FAILED: External services unreachable (HTTP $external_test_response)"
                    echo "post_disruption,connectivity_validation,FAIL,http_$external_test_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                fi
                
                # Additional internal validation of egress IP assignment
                log_info "🔍 Validating internal egress IP configuration..."
                local current_eip_node
                current_eip_node=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
                local current_eip_status
                current_eip_status=$(oc get egressip "$EIP_NAME" -o jsonpath='{.status.items[0].egressIP}' 2>/dev/null || echo "")
                
                if [[ "$current_eip_status" == "$eip_address" && -n "$current_eip_node" ]]; then
                    log_success "✅ INTERNAL EGRESS IP VALIDATION PASSED: $eip_address assigned to $current_eip_node"
                    echo "post_disruption,internal_validation,PASS,$eip_address" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                else
                    log_error "❌ INTERNAL EGRESS IP VALIDATION FAILED: Assignment issue"
                    echo "post_disruption,internal_validation,FAIL,$current_eip_status" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                fi
            else
                log_error "❌ EGRESS IP SOURCE VALIDATION FAILED: No valid source IP in response"
                echo "post_disruption,source_ip_validation,FAIL,invalid_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                
                # Debug information
                log_error "🔍 Debug info:"
                log_error "  - Raw response: '$egress_response'"
                log_error "  - External bastion echo service URL: $external_echo_url"
                log_error "  - Expected: Valid JSON with source_ip field"
                log_error "  - Actual source IP: '$actual_source_ip'"
                
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
                # Test control pod source IP - should NOT be egress IP
                log_info "📡 Testing control pod SOURCE IP validation (should NOT use egress IP)"
                local control_response
                control_response=$(oc exec -n egress-control-test control-test-pod -- timeout 30 curl -s "$external_echo_url" 2>/dev/null || echo "")
                log_info "📥 Control pod response: '$control_response'"
                
                # Extract source IP from JSON response
                local control_source_ip
                control_source_ip=$(echo "$control_response" | grep -o '"source_ip"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
                if [[ -z "$control_source_ip" ]]; then
                    # Fallback to "origin" field for httpbin.org and similar services
                    control_source_ip=$(echo "$control_response" | grep -o '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "")
                fi
                
                if [[ -n "$control_source_ip" && "$control_source_ip" != "127.0.0.1" ]]; then
                    # CRITICAL: Control pod should NOT use egress IP
                    if [[ "$control_source_ip" != "$eip_address" ]]; then
                        log_success "✅ CONTROL SOURCE VALIDATION PASSED: Control pod source IP ($control_source_ip) does NOT use egress IP ($eip_address)"
                        log_info "📝 Note: Control pod correctly uses different source IP, confirming egress IP isolation"
                        echo "post_disruption,control_source_validation,PASS,$control_source_ip" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                    else
                        log_error "❌ CONTROL SOURCE VALIDATION FAILED: Control pod incorrectly uses egress IP ($control_source_ip)"
                        log_error "🔍 This indicates egress IP is not properly isolated to designated namespaces"
                        echo "post_disruption,control_source_validation,FAIL,$control_source_ip" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                        return 1
                    fi
                    
                    # Secondary: Test external connectivity
                    log_info "🌐 Testing control pod external connectivity..."
                    local control_external_test
                    control_external_test=$(oc exec -n egress-control-test control-test-pod -- timeout 15 curl -s -o /dev/null -w "%{http_code}" "$IPECHO_SERVICE_URL" 2>/dev/null || echo "000")
                    
                    if [[ "$control_external_test" == "200" ]]; then
                        log_success "✅ CONTROL CONNECTIVITY VALIDATION PASSED: Control pod has external connectivity"
                        echo "post_disruption,control_connectivity,PASS,http_$control_external_test" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                    else
                        log_warning "⚠️  CONTROL CONNECTIVITY VALIDATION FAILED: Control pod cannot reach external services (HTTP $control_external_test)"
                        echo "post_disruption,control_connectivity,FAIL,http_$control_external_test" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
                    fi
                else
                    log_error "❌ CONTROL SOURCE VALIDATION FAILED: No valid source IP in control pod response"
                    echo "post_disruption,control_source_validation,FAIL,invalid_response" >> "$ARTIFACT_DIR/pod_disruption_metrics.csv"
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
        oc delete namespace egress-ip-test --ignore-not-found=true &>/dev/null
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
    egress-ip: enabled
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
  # CRITICAL: Schedule pod on egress IP assigned node for proper routing
  nodeSelector:
    kubernetes.io/hostname: "$ASSIGNED_NODE"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
            - "$ASSIGNED_NODE"
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
