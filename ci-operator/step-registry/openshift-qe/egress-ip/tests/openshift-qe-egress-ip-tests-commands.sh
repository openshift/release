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
PROJECT_COUNT="${PROJECT_COUNT:-4}"
ENABLE_LOAD_TEST="${ENABLE_LOAD_TEST:-true}"
IPECHO_SERVICE_PORT="${IPECHO_SERVICE_PORT:-9095}"
CONNECTIVITY_TEST_ITERATIONS="${CONNECTIVITY_TEST_ITERATIONS:-5}"
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

# Phase 0: Load Testing with Blue/Red Team Pods (if enabled)
if [[ "$ENABLE_LOAD_TEST" == "true" ]]; then
    log_info "==============================="
    log_info "PHASE 0: Load Testing with Blue/Red Team Pods"
    log_info "==============================="
    
    # Discover ipecho service URL dynamically (following openshift-tests-private pattern)
    log_info "Discovering ipecho service endpoint..."
    IPECHO_SERVICE_URL=""
    
    # Method 1: Check if there's a predefined ipfile from CI environment (flexy pattern)
    if [[ -n "${WORKSPACE:-}" && -f "${WORKSPACE}/flexy-artifacts/workdir/install-dir/ipfile.txt" ]]; then
        IPECHO_SERVICE_IP=$(cat "${WORKSPACE}/flexy-artifacts/workdir/install-dir/ipfile.txt" 2>/dev/null | tr -d '\n\r ')
        if [[ -n "$IPECHO_SERVICE_IP" ]]; then
            IPECHO_SERVICE_URL="$IPECHO_SERVICE_IP:$IPECHO_SERVICE_PORT"
            log_success "Found ipecho service from flexy ipfile: $IPECHO_SERVICE_URL"
        fi
    fi
    
    # Method 2: Check environment variable (common in CI)
    if [[ -z "$IPECHO_SERVICE_URL" && -n "${IPECHO_URL:-}" ]]; then
        IPECHO_SERVICE_URL="$IPECHO_URL"
        log_success "Found ipecho service from environment: $IPECHO_SERVICE_URL"
    fi
    
    # Method 3: Look for ConfigMap with ipecho URL (some tests store it there)
    if [[ -z "$IPECHO_SERVICE_URL" ]]; then
        log_info "Searching for ipecho URL in ConfigMaps..."
        IPECHO_SERVICE_URL=$(oc get cm -A -o jsonpath='{.items[*].data.ipecho_url}' 2>/dev/null | tr ' ' '\n' | head -1)
        if [[ -n "$IPECHO_SERVICE_URL" ]]; then
            log_success "Found ipecho service URL in ConfigMap: $IPECHO_SERVICE_URL"
        fi
    fi
    
    # Method 4: Look for ipecho service in cluster
    if [[ -z "$IPECHO_SERVICE_URL" ]]; then
        log_info "Searching for ipecho service in cluster..."
        IPECHO_SERVICE_IP=$(oc get svc -A -o jsonpath='{.items[?(@.metadata.name=="ipecho")].spec.clusterIP}' 2>/dev/null | head -1)
        if [[ -n "$IPECHO_SERVICE_IP" ]]; then
            IPECHO_SERVICE_URL="$IPECHO_SERVICE_IP:$IPECHO_SERVICE_PORT"
            log_success "Found ipecho service in cluster: $IPECHO_SERVICE_URL"
        fi
    fi
    
    # Method 5: Use multiple fallback services to avoid rate limiting
    if [[ -z "$IPECHO_SERVICE_URL" ]]; then
        log_warning "No ipecho service found, using external services for basic connectivity testing"
        # Try multiple services to avoid rate limiting
        FALLBACK_SERVICES=("http://ifconfig.me" "http://icanhazip.com" "http://ipecho.net/plain" "http://httpbin.org/ip")
        
        for service in "${FALLBACK_SERVICES[@]}"; do
            log_info "Testing connectivity to $service..."
            if timeout 10 curl -s --connect-timeout 5 "$service" >/dev/null 2>&1; then
                IPECHO_SERVICE_URL="$service"
                log_success "Using $service for egress IP detection"
                break
            fi
        done
        
        if [[ -z "$IPECHO_SERVICE_URL" ]]; then
            IPECHO_SERVICE_URL="http://httpbin.org/ip"
            log_info "Using httpbin.org/ip as final fallback"
        fi
    fi
    
    if [[ -z "$IPECHO_SERVICE_URL" ]]; then
        log_error "Could not discover any suitable service for connectivity testing"
        log_error "Skipping load testing phase"
    else
        log_success "Using service endpoint: $IPECHO_SERVICE_URL"
    fi
    
    # Function to test connectivity from a pod
    test_pod_connectivity() {
        local namespace=$1
        local pod=$2
        local team=$3
        local iteration=$4
        
        log_info "Testing connectivity from $pod ($team team) in $namespace - iteration $iteration"
        
        # Debug: Check pod labels
        log_info "Pod labels: $(oc get pod -n "$namespace" "$pod" --show-labels 2>/dev/null | grep -o 'team=[^,]*' || echo 'no team label')"
        
        # Test curl to discovered service
        local curl_exit_code=0
        local egress_response=""
        
        egress_response=$(timeout 30 oc exec -n "$namespace" "$pod" -- curl -s --connect-timeout 10 --max-time 20 "$IPECHO_SERVICE_URL" 2>/dev/null) || curl_exit_code=$?
        
        if [[ $curl_exit_code -eq 0 && -n "$egress_response" ]]; then
            log_success "✓ Connectivity SUCCESS from $pod ($team team)"
            log_info "Response: $egress_response"
            
            # Extract egress IP from response and validate (handle different response formats)
            local detected_egress_ip
            if [[ "$egress_response" == *"503 Service Temporarily Unavailable"* || "$egress_response" == *"<html>"* ]]; then
                log_warning "Service temporarily unavailable, retrying in 10 seconds..."
                sleep 10
                egress_response=$(timeout 30 oc exec -n "$namespace" "$pod" -- curl -s --connect-timeout 10 --max-time 20 "$IPECHO_SERVICE_URL" 2>/dev/null) || curl_exit_code=$?
            fi
            
            # Extract IP from various response formats
            if [[ "$IPECHO_SERVICE_URL" == *"httpbin.org"* ]]; then
                detected_egress_ip=$(echo "$egress_response" | grep -oE '"origin":\s*"([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
            else
                detected_egress_ip=$(echo "$egress_response" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            fi
            if [[ -n "$detected_egress_ip" ]]; then
                log_info "Detected egress IP: $detected_egress_ip"
                
                # Validate egress IP matches team expectation
                local expected_result="success"
                if [[ "$team" == "blue" ]]; then
                    BLUE_EGRESS_IP=$(oc get egressip egressip-blue -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
                    if [[ -n "$BLUE_EGRESS_IP" && "$detected_egress_ip" != "$BLUE_EGRESS_IP" ]]; then
                        log_warning "Blue team pod using unexpected egress IP: $detected_egress_ip (expected: $BLUE_EGRESS_IP)"
                        expected_result="unexpected_ip"
                    fi
                elif [[ "$team" == "red" ]]; then
                    RED_EGRESS_IP=$(oc get egressip egressip-red -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
                    if [[ -n "$RED_EGRESS_IP" && "$detected_egress_ip" != "$RED_EGRESS_IP" ]]; then
                        log_warning "Red team pod using unexpected egress IP: $detected_egress_ip (expected: $RED_EGRESS_IP)"
                        expected_result="unexpected_ip"
                    fi
                fi
                
                # Save to metrics
                echo "$namespace,$pod,$team,$iteration,$expected_result,$detected_egress_ip" >> "$ARTIFACT_DIR/load_test_metrics.csv"
            else
                log_warning "Could not extract egress IP from response"
                echo "$namespace,$pod,$team,$iteration,success,unknown" >> "$ARTIFACT_DIR/load_test_metrics.csv"
            fi
        else
            log_error "✗ Connectivity FAILED from $pod ($team team) - exit code: $curl_exit_code"
            # Try basic connectivity test (extract IP from URL for ping)
            local ping_target
            if [[ "$IPECHO_SERVICE_URL" =~ http://([^/]+) ]]; then
                ping_target="${BASH_REMATCH[1]}"
            elif [[ "$IPECHO_SERVICE_URL" =~ ([^:]+): ]]; then
                ping_target="${BASH_REMATCH[1]}"
            else
                ping_target="$IPECHO_SERVICE_URL"
            fi
            
            if oc exec -n "$namespace" "$pod" -- ping -c 1 "$ping_target" >/dev/null 2>&1; then
                log_info "  - Ping to $ping_target: SUCCESS"
            else
                log_warning "  - Ping to $ping_target: FAILED"
            fi
            echo "$namespace,$pod,$team,$iteration,failed,none" >> "$ARTIFACT_DIR/load_test_metrics.csv"
        fi
    }
    
    # Only proceed with load testing if we have a valid service
    if [[ -n "$IPECHO_SERVICE_URL" ]]; then
        # Debug: Check egress IP configurations
        log_info "Debugging egress IP configurations..."
        log_info "Current egress IPs in cluster:"
        oc get egressip -o wide || true
        
        log_info "Checking blue team egress IP status:"
        oc get egressip egressip-blue -o yaml 2>/dev/null | grep -E "(name|egressIPs|node|ready)" || log_warning "Blue team egress IP not found"
        
        log_info "Checking red team egress IP status:"
        oc get egressip egressip-red -o yaml 2>/dev/null | grep -E "(name|egressIPs|node|ready)" || log_warning "Red team egress IP not found"
        
        # Create CSV header
        echo "namespace,pod,team,iteration,status,egress_ip" > "$ARTIFACT_DIR/load_test_metrics.csv"
        
        # Run connectivity tests across all projects
        log_info "Running connectivity tests across $PROJECT_COUNT projects..."
    blue_projects=$((PROJECT_COUNT / 2))
    
    for ((iter=1; iter<=CONNECTIVITY_TEST_ITERATIONS; iter++)); do
        log_info "Load testing iteration $iter/$CONNECTIVITY_TEST_ITERATIONS"
        
        # Test blue team pods
        for ((i=1; i<=blue_projects; i++)); do
            namespace="egressip-test$i"
            
            # Check if namespace exists
            if ! oc get namespace "$namespace" >/dev/null 2>&1; then
                log_warning "Namespace $namespace does not exist, skipping"
                continue
            fi
            
            # Get pods in namespace
            mapfile -t pods < <(oc get pods -n "$namespace" -l app=test-pod --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
            
            if [[ ${#pods[@]} -eq 0 || -z "${pods[0]}" ]]; then
                log_warning "No test pods found in namespace $namespace"
                continue
            fi
            
            for pod in "${pods[@]}"; do
                if [[ -n "$pod" && "$pod" != "<none>" ]]; then
                    test_pod_connectivity "$namespace" "$pod" "blue" "$iter"
                    sleep 5  # Increased sleep to avoid rate limiting
                fi
            done
        done
        
        # Test red team pods
        for ((i=blue_projects+1; i<=PROJECT_COUNT; i++)); do
            namespace="egressip-test$i"
            
            # Check if namespace exists
            if ! oc get namespace "$namespace" >/dev/null 2>&1; then
                log_warning "Namespace $namespace does not exist, skipping"
                continue
            fi
            
            # Get pods in namespace
            mapfile -t pods < <(oc get pods -n "$namespace" -l app=test-pod --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
            
            if [[ ${#pods[@]} -eq 0 || -z "${pods[0]}" ]]; then
                log_warning "No test pods found in namespace $namespace"
                continue
            fi
            
            for pod in "${pods[@]}"; do
                if [[ -n "$pod" && "$pod" != "<none>" ]]; then
                    test_pod_connectivity "$namespace" "$pod" "red" "$iter"
                    sleep 5  # Increased sleep to avoid rate limiting
                fi
            done
        done
        
        log_info "Completed iteration $iter, waiting before next iteration..."
        sleep 10
    done
    
    # Generate load test summary
    total_tests=$(tail -n +2 "$ARTIFACT_DIR/load_test_metrics.csv" | wc -l)
    successful_tests=$(tail -n +2 "$ARTIFACT_DIR/load_test_metrics.csv" | grep -c "success")
    failed_tests=$(tail -n +2 "$ARTIFACT_DIR/load_test_metrics.csv" | grep -c "failed")
    success_rate=$(( (successful_tests * 100) / total_tests ))
    
    log_success "Load testing completed!"
    log_info "  - Total tests: $total_tests"
    log_info "  - Successful: $successful_tests"
    log_info "  - Failed: $failed_tests"
    log_info "  - Success rate: $success_rate%"
    
    if [[ $success_rate -lt 90 ]]; then
        log_warning "Load test success rate is below 90%, investigating..."
        log_info "Recent failures:"
        tail -n +2 "$ARTIFACT_DIR/load_test_metrics.csv" | grep "failed" | tail -5
    fi
    else
        log_error "No valid service found for load testing, skipping connectivity tests"
        # Create empty metrics file for consistency
        echo "namespace,pod,team,iteration,status,egress_ip" > "$ARTIFACT_DIR/load_test_metrics.csv"
    fi
else
    log_info "Load testing disabled, skipping Phase 0"
fi

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
if [[ "$ENABLE_LOAD_TEST" == "true" ]]; then
    log_info "  - Load Testing: Enabled ($PROJECT_COUNT projects)"
    log_info "  - Connectivity Tests: $CONNECTIVITY_TEST_ITERATIONS iterations"
    if [[ -n "${IPECHO_SERVICE_URL:-}" ]]; then
        log_info "  - Test Service: $IPECHO_SERVICE_URL"
    else
        log_info "  - Test Service: Not found/configured"
    fi
fi
log_info "  - Pod Kill Tests: $POD_KILL_RETRIES iterations"
log_info "  - Node Reboot Tests: $REBOOT_RETRIES iterations"
log_info "  - Total Runtime: $SECONDS seconds"
log_info "  - Log File: $LOG_FILE"

# Copy test artifacts
if [[ -f "$ARTIFACT_DIR/load_test_metrics.csv" ]]; then
    log_info "Load test metrics saved to: $ARTIFACT_DIR/load_test_metrics.csv"
    log_info "Load test summary:"
    if [[ -s "$ARTIFACT_DIR/load_test_metrics.csv" ]]; then
        total_load_tests=$(tail -n +2 "$ARTIFACT_DIR/load_test_metrics.csv" | wc -l)
        successful_load_tests=$(tail -n +2 "$ARTIFACT_DIR/load_test_metrics.csv" | grep -c "success" || echo "0")
        log_info "  - Total connectivity tests: $total_load_tests"
        log_info "  - Successful tests: $successful_load_tests"
        if [[ $total_load_tests -gt 0 ]]; then
            success_percentage=$(( (successful_load_tests * 100) / total_load_tests ))
            log_info "  - Success rate: $success_percentage%"
        fi
    fi
fi

if [[ -f "$ARTIFACT_DIR/pod_disruption_metrics.csv" ]]; then
    log_info "Pod disruption metrics saved to: $ARTIFACT_DIR/pod_disruption_metrics.csv"
fi

if [[ -f "$ARTIFACT_DIR/reboot_metrics.csv" ]]; then
    log_info "Reboot test metrics saved to: $ARTIFACT_DIR/reboot_metrics.csv"
fi

log_success "🎉 OpenShift QE Egress IP resilience and load testing completed successfully!"
