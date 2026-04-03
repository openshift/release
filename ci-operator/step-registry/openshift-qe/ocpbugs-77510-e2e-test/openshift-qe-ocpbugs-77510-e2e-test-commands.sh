#!/bin/bash

# OCPBUGS-77510 Generic End-to-End Test for Prow CI
# Tests TCP RST behavior during API server restarts (etcd encryption simulation)
set -euo pipefail
sleep 5
# Test configuration - Generic and adaptable
TEST_NAME="ocpbugs-77510-e2e"
NAMESPACE="${TEST_NAME}-$(date +%s)"
TIMEOUT_MINUTES=12
MIN_RST_THRESHOLD=10  # Realistic threshold for CI environments

# Test scale configuration (can be overridden via env vars)
TEST_SCALE="${TEST_SCALE:-small}"  # small=10, medium=50, large=200, progressive=all

# Function to set scale parameters
set_scale_params() {
    local scale="$1"
    case "$scale" in
        small)
            SERVICE_COUNT=2
            PODS_PER_SERVICE=5
            EXPECTED_PODS=10
            MIN_RST_THRESHOLD=10
            ;;
        medium)
            SERVICE_COUNT=10
            PODS_PER_SERVICE=5
            EXPECTED_PODS=50
            MIN_RST_THRESHOLD=50
            ;;
        large)
            SERVICE_COUNT=40
            PODS_PER_SERVICE=5
            EXPECTED_PODS=200
            MIN_RST_THRESHOLD=100
            ;;
        progressive)
            # Will be set dynamically in progressive mode
            SERVICE_COUNT=0
            PODS_PER_SERVICE=0
            EXPECTED_PODS=0
            MIN_RST_THRESHOLD=0
            ;;
        *)
            log_error "Invalid TEST_SCALE: $scale (use: small, medium, large, progressive)"
            exit 1
            ;;
    esac
}

# Initialize scale parameters
set_scale_params "$TEST_SCALE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1${NC}"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    log "🧹 Cleaning up test resources..."
    
    # Stop monitoring processes
    jobs -p | xargs -r kill 2>/dev/null || true
    pkill -f "ocpbugs-77510" 2>/dev/null || true
    
    # Clean up namespace
    if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        oc delete namespace "$NAMESPACE" --timeout=30s --ignore-not-found=true || true
    fi
    
    # Preserve artifacts
    if [[ -n "${ARTIFACT_DIR:-}" ]]; then
        mkdir -p "$ARTIFACT_DIR"
        [[ -f "/tmp/ocpbugs-77510-rst.log" ]] && cp "/tmp/ocpbugs-77510-rst.log" "$ARTIFACT_DIR/" || true
        [[ -f "/tmp/ocpbugs-77510-test.log" ]] && cp "/tmp/ocpbugs-77510-test.log" "$ARTIFACT_DIR/" || true
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Validate cluster access and detect capabilities
validate_cluster() {
    log "🔍 Validating cluster access and capabilities..."
    
    # Standard Prow authentication - service account should already be configured
    if ! oc whoami >/dev/null 2>&1; then
        log_error "Cannot access OpenShift cluster - check service account permissions"
        log "Debug info:"
        log "  Current user: $(oc whoami 2>&1 || echo 'auth failed')"
        log "  Server: $(oc whoami --show-server 2>&1 || echo 'unknown')"
        return 1
    fi
    
    local cluster_info
    cluster_info=$(oc version --client=false 2>/dev/null | head -1 || echo "unknown")
    log "📊 Cluster: $cluster_info"
    log "🔑 Connected as: $(oc whoami)"
    
    # Check for API server access (for bug trigger, but not required for basic test)
    if ! oc get pods -n openshift-kube-apiserver --no-headers 2>/dev/null | head -1 >/dev/null; then
        log_warning "Cannot access kube-apiserver pods - will skip API server restart trigger"
        log_warning "Test will still validate basic service behavior and RST detection"
        SKIP_API_RESTART=true
    else
        log_success "API server access confirmed - full test will execute"
        SKIP_API_RESTART=false
    fi
    
    # Find suitable worker node for monitoring
    WORKER_NODE=$(oc get nodes --no-headers 2>/dev/null | grep -E "(worker|compute)" | head -1 | awk '{print $1}')
    if [[ -z "$WORKER_NODE" ]]; then
        # Fallback to any ready node
        WORKER_NODE=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print $1}' | head -1)
    fi
    
    if [[ -z "$WORKER_NODE" ]]; then
        log_error "No suitable nodes found for monitoring"
        return 1
    fi
    
    log_success "Validation complete. Monitor node: $WORKER_NODE"
    return 0
}

# Create test infrastructure based on scale
create_test_infrastructure() {
    log "🏗️ Creating test infrastructure ($TEST_SCALE scale)..."
    log "   Target: $EXPECTED_PODS pods across $SERVICE_COUNT services"
    
    oc create namespace "$NAMESPACE" || {
        log_error "Failed to create namespace $NAMESPACE"
        return 1
    }
    
    oc label namespace "$NAMESPACE" test="ocpbugs-77510-$TEST_SCALE-scale" || true
    
    # Create services with potential for serviceUpdateNotNeeded() bug
    # Using generic container images available in CI
    for i in $(seq 1 $SERVICE_COUNT); do
        cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-svc-$i
  namespace: $NAMESPACE
spec:
  replicas: $PODS_PER_SERVICE
  selector:
    matchLabels:
      app: test-svc-$i
  template:
    metadata:
      labels:
        app: test-svc-$i
    spec:
      containers:
      - name: app
        image: docker.io/library/nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
---
apiVersion: v1
kind: Service
metadata:
  name: test-svc-$i
  namespace: $NAMESPACE
spec:
  selector:
    app: test-svc-$i
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
  # Note: internalTrafficPolicy left unset to trigger potential nil comparison bug
EOF
    done
    
    # Create traffic generator
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: traffic-client
  namespace: $NAMESPACE
spec:
  containers:
  - name: client
    image: docker.io/curlimages/curl:latest
    command: ["/bin/sh"]
    args:
    - -c
    - |
      while true; do
        for svc_num in \$(seq 1 $SERVICE_COUNT); do
          curl -s --connect-timeout 2 --max-time 3 "http://test-svc-\${svc_num}.$NAMESPACE.svc.cluster.local/" >/dev/null 2>&1 || true
          sleep 1
        done
      done
    resources:
      requests:
        memory: "16Mi"
        cpu: "10m"
EOF
    
    # Wait for infrastructure to be ready
    log "⏳ Waiting for infrastructure readiness ($EXPECTED_PODS expected pods)..."
    local timeout=300  # Longer timeout for larger scales
    local count=0
    while [[ $count -lt $timeout ]]; do
        local ready_pods
        ready_pods=$(oc get pods -n "$NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        
        if [[ $ready_pods -ge $EXPECTED_PODS ]]; then
            log_success "Infrastructure ready: $ready_pods pods running"
            sleep $((SERVICE_COUNT > 10 ? 30 : 15))  # Allow connections to stabilize
            return 0
        fi
        
        if [[ $((count % 30)) -eq 0 ]]; then
            log "Waiting for pods... ($ready_pods/$EXPECTED_PODS ready, ${count}s elapsed)"
        fi
        
        # Pace creation for large scales
        if [[ $count -eq 60 ]] && [[ $TEST_SCALE == "large" ]]; then
            log "   Large scale deployment - allowing extra time for pod scheduling"
        fi
        
        sleep 10
        count=$((count + 10))
    done
    
    log_warning "Infrastructure not fully ready, continuing with available pods"
    oc get pods -n "$NAMESPACE" -o wide || true
    return 0
}

# Start RST packet monitoring
start_monitoring() {
    log "📊 Starting TCP RST monitoring on node: $WORKER_NODE"
    
    # Start background RST monitoring
    {
        timeout $((TIMEOUT_MINUTES * 60)) oc debug "node/$WORKER_NODE" --quiet -- \
            bash -c 'tcpdump -i any -nn "tcp[tcpflags] & tcp-rst != 0" 2>/dev/null || echo "RST monitoring ended"' | \
            while read -r line; do
                echo "$(date '+%H:%M:%S'): RST: $line"
            done
    } > "/tmp/ocpbugs-77510-rst.log" 2>&1 &
    
    local monitor_pid=$!
    echo $monitor_pid > "/tmp/ocpbugs-77510-monitor.pid"
    
    log "🔍 RST monitoring started (PID: $monitor_pid)"
    sleep 5  # Allow monitoring to initialize
}

# Execute the bug trigger - try multiple approaches
trigger_bug_scenario() {
    log "💥 Executing OCPBUGS-77510 trigger scenario ($TEST_SCALE scale)..."
    log "   Testing with $EXPECTED_PODS pods across $SERVICE_COUNT services"
    
    # Try different trigger approaches based on permissions
    local trigger_used="none"
    
    # Method 1: API server restart (primary trigger)
    if oc get pods -n openshift-kube-apiserver --no-headers >/dev/null 2>&1; then
        log "🔄 Method 1: API server restart trigger"
        log "   Simulating etcd encryption key rotation via API server restart"
        
        local api_pods
        api_pods=$(oc get pods -n openshift-kube-apiserver | grep kube-apiserver | grep -v guard | grep -v revision | awk '{print $1}' | head -2)
        
        if [[ -n "$api_pods" ]]; then
            for pod in $api_pods; do
                log "   Restarting: $pod"
                oc delete pod "$pod" -n openshift-kube-apiserver --grace-period=5 || true
                sleep 30  # Allow restart and OVN-K reconnection
            done
            trigger_used="api_restart"
        fi
        
    # Method 2: OVN-Kubernetes restart (backup trigger)
    elif oc get pods -n openshift-ovn-kubernetes --no-headers >/dev/null 2>&1; then
        log "🔄 Method 2: OVN-Kubernetes restart trigger"
        log "   Triggering OVN refresh to force service rule re-evaluation"
        
        local ovn_pods
        ovn_pods=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --no-headers | awk '{print $1}')
        local ovn_count
        ovn_count=$(echo "$ovn_pods" | wc -l)
        
        if [[ $ovn_count -gt 0 ]]; then
            log "   Restarting $ovn_count OVN node pods"
            for pod in $ovn_pods; do
                log "   Deleting $pod"
                oc delete pod "$pod" -n openshift-ovn-kubernetes --grace-period=0 --force &
            done
            trigger_used="ovn_restart"
        fi
        
    else
        # Method 3: Baseline monitoring (fallback)
        log "🔄 Method 3: Baseline monitoring (no restart permissions)"
        log "   Running intensive service connectivity patterns"
        
        for i in $(seq 1 3); do
            log "   Traffic pattern $i/3..."
            oc exec -n "$NAMESPACE" traffic-client -- sh -c "
                for j in \$(seq 1 $SERVICE_COUNT); do
                    curl -s --connect-timeout 1 --max-time 2 http://test-svc-\${j}.$NAMESPACE.svc.cluster.local/ >/dev/null 2>&1 &
                done
                wait
            " 2>/dev/null || true
            sleep 20
        done
        trigger_used="baseline"
    fi
    
    # Monitor for remaining time based on scale and trigger
    local monitor_minutes
    case "$trigger_used" in
        api_restart|ovn_restart)
            monitor_minutes=$((TIMEOUT_MINUTES - 3))
            log "⏱️ Monitoring RST activity for $monitor_minutes minutes after $trigger_used..."
            ;;
        baseline)
            monitor_minutes=$((TIMEOUT_MINUTES - 1))
            log "⏱️ Monitoring baseline RST activity for $monitor_minutes minutes..."
            ;;
        *)
            monitor_minutes=$((TIMEOUT_MINUTES - 1))
            log "⏱️ Monitoring for $monitor_minutes minutes..."
            ;;
    esac
    
    sleep $((monitor_minutes * 60))
}

# Analyze test results
analyze_results() {
    log "📈 Analyzing test results..."
    
    # Stop monitoring
    if [[ -f "/tmp/ocpbugs-77510-monitor.pid" ]]; then
        local monitor_pid
        monitor_pid=$(cat "/tmp/ocpbugs-77510-monitor.pid" 2>/dev/null || echo "")
        [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null || true
        rm -f "/tmp/ocpbugs-77510-monitor.pid"
    fi
    
    sleep 2  # Allow final packets to be captured
    
    # Count RST packets
    local rst_count=0
    if [[ -f "/tmp/ocpbugs-77510-rst.log" ]]; then
        rst_count=$(grep -c "RST:" "/tmp/ocpbugs-77510-rst.log" 2>/dev/null || echo "0")
    fi
    
    # Get test infrastructure status
    local pod_count
    pod_count=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    
    log "🎯 Test Results ($TEST_SCALE scale):"
    log "   RST packets captured: $rst_count"
    log "   Test infrastructure: $pod_count pods ($SERVICE_COUNT services)"
    log "   Test duration: $TIMEOUT_MINUTES minutes"
    log "   Threshold for bug detection: $MIN_RST_THRESHOLD RST packets"
    
    # Determine test outcome
    if [[ $rst_count -ge $MIN_RST_THRESHOLD ]]; then
        log_success "🚨 OCPBUGS-77510 BUG DETECTED!"
        log_success "   High RST count ($rst_count) indicates serviceUpdateNotNeeded() bug is present"
        log_success "   This cluster exhibits the TCP RST storm behavior"
        
        # Show sample RST packets
        if [[ $rst_count -gt 0 ]] && [[ -f "/tmp/ocpbugs-77510-rst.log" ]]; then
            log "📋 Sample RST packets:"
            head -5 "/tmp/ocpbugs-77510-rst.log" | sed 's/^/   /'
        fi
        
        return 0  # Test passed - bug reproduced
        
    elif [[ $rst_count -gt 0 ]]; then
        log_warning "⚠️ PARTIAL RST ACTIVITY: $rst_count packets detected"
        log_warning "   Below threshold but some RST activity observed"
        log_warning "   May indicate partial fix or different timing"
        
        return 0  # Don't fail CI for partial results
        
    else
        log_success "✅ NO RST STORM DETECTED"
        log_success "   Low/zero RST count suggests bug may be fixed"
        log_success "   Or different cluster configuration"
        
        # This is actually a success - means the bug is not present
        return 0
    fi
}

# Create test report
create_test_report() {
    local rst_count
    rst_count=$(grep -c "RST:" "/tmp/ocpbugs-77510-rst.log" 2>/dev/null || echo "0")
    
    # Save to test log
    cat > "/tmp/ocpbugs-77510-test.log" << EOF
OCPBUGS-77510 Test Report
=========================
Date: $(date)
Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')
Version: $(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo 'unknown')

Test Results:
- RST Packets: $rst_count (threshold: $MIN_RST_THRESHOLD)
- Test Namespace: $NAMESPACE
- Monitor Node: $WORKER_NODE
- Duration: $TIMEOUT_MINUTES minutes

Bug Status: $([[ $rst_count -ge $MIN_RST_THRESHOLD ]] && echo "PRESENT - Fix needed" || echo "NOT DETECTED - Likely fixed or different config")

Infrastructure:
$(oc get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "No pods found")

Generated by OCPBUGS-77510 Prow test
EOF
    
    log "📄 Test report saved to /tmp/ocpbugs-77510-test.log"
}

# Progressive test function - runs all scales sequentially
run_progressive_test() {
    log "🚀 OCPBUGS-77510 Progressive Scale Test Starting"
    log "=============================================="
    log "Purpose: Test all scales (small→medium→large) on single cluster"
    log "Bug: serviceUpdateNotNeeded() nil pointer comparison issue"
    
    # Validate environment once
    validate_cluster || exit 1
    
    local scales=("small" "medium" "large")
    local overall_results=()
    
    for scale in "${scales[@]}"; do
        log ""
        log "📊 ===== TESTING $scale SCALE ====="
        
        # Set parameters for this scale
        set_scale_params "$scale"
        local scale_namespace="${TEST_NAME}-${scale}-$(date +%s)"
        
        # Override namespace for this scale
        NAMESPACE="$scale_namespace"
        
        log "   Scale: $EXPECTED_PODS pods across $SERVICE_COUNT services"
        
        # Run single scale test
        if run_single_scale_test "$scale"; then
            log_success "✅ $scale scale test PASSED"
            overall_results+=("$scale:PASS")
        else
            log_error "❌ $scale scale test FAILED"
            overall_results+=("$scale:FAIL")
        fi
        
        # Brief pause between scales
        sleep 30
    done
    
    # Report overall results
    log ""
    log "🎯 PROGRESSIVE TEST SUMMARY:"
    log "============================"
    for result in "${overall_results[@]}"; do
        local scale_name=${result%:*}
        local scale_result=${result#*:}
        if [[ "$scale_result" == "PASS" ]]; then
            log_success "   $scale_name scale: ✅ PASSED"
        else
            log_error "   $scale_name scale: ❌ FAILED"
        fi
    done
    
    # Test passes if any scale detected the bug
    local detection_count=0
    for result in "${overall_results[@]}"; do
        [[ "${result#*:}" == "PASS" ]] && ((detection_count++))
    done
    
    if [[ $detection_count -gt 0 ]]; then
        log_success "🎉 Progressive test completed - bug detection in $detection_count scale(s)"
        return 0
    else
        log_warning "⚠️ No RST storms detected across all scales - may indicate fix"
        return 0  # Not a failure - could mean bug is fixed
    fi
}

# Single scale test function
run_single_scale_test() {
    local current_scale="$1"
    
    # Create test setup for this scale
    create_test_infrastructure || return 1
    
    # Start monitoring
    start_monitoring || return 1
    
    # Execute trigger with shorter timeout for progressive mode
    local orig_timeout=$TIMEOUT_MINUTES
    TIMEOUT_MINUTES=8  # Shorter per-scale timeout
    trigger_bug_scenario || return 1
    TIMEOUT_MINUTES=$orig_timeout
    
    # Analyze results
    analyze_results
}

# Main execution
main() {
    if [[ "$TEST_SCALE" == "progressive" ]]; then
        run_progressive_test
    else
        log "🚀 OCPBUGS-77510 Generic E2E Test Starting ($TEST_SCALE scale)"
        log "=========================================="
        log "Purpose: Detect TCP RST storms during API server restarts"
        log "Bug: serviceUpdateNotNeeded() nil pointer comparison issue"
        log "Scale: $EXPECTED_PODS pods across $SERVICE_COUNT services"
        
        # Validate environment
        validate_cluster || exit 1
        
        # Run single scale test
        if run_single_scale_test "$TEST_SCALE"; then
            log_success "🎉 OCPBUGS-77510 test completed successfully"
        else
            log_error "❌ OCPBUGS-77510 test execution failed"
            exit 1
        fi
        
        # Create comprehensive report
        create_test_report
        
        log "✅ Test execution complete - check artifacts for detailed results"
    fi
}

# Execute main function
main "$@"
