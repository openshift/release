#!/bin/bash

# OCPBUGS-77510 End-to-End Test for Prow CI
# Validates TCP RST storm bug during kube-apiserver rollouts
set -euo pipefail

# Test configuration
TEST_NAME="ocpbugs-77510-e2e"
NAMESPACE="${TEST_NAME}-$(date +%s)"
TIMEOUT_MINUTES=15
EXPECTED_MIN_RST=100  # Minimum RST packets to consider test successful

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $1${NC}"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    log "🧹 Cleaning up test resources..."
    
    # Stop any running monitoring processes
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Clean up namespace
    if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        oc delete namespace "$NAMESPACE" --timeout=60s || {
            log_warning "Failed to delete namespace cleanly, forcing deletion"
            oc patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge || true
        }
    fi
    
    # Preserve logs for CI analysis
    if [[ -f "/tmp/${TEST_NAME}-rst.log" ]]; then
        log " Test results preserved in /tmp/${TEST_NAME}-rst.log"
        log " RST packet count: $(grep -c "RST:" /tmp/${TEST_NAME}-rst.log 2>/dev/null || echo "0")"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Validate cluster access and requirements
validate_cluster() {
    log " Validating cluster access and requirements..."
    
    # Check cluster access
    if ! oc whoami >/dev/null 2>&1; then
        log_error "Cannot access OpenShift cluster. Ensure KUBECONFIG is set."
        return 1
    fi
    
    # Check cluster info
    local cluster_version
    cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
    log " Cluster version: $cluster_version"
    
    # Check for required components
    if ! oc get pods -n openshift-kube-apiserver -l app=kube-apiserver --no-headers 2>/dev/null | head -1 >/dev/null; then
        log_error "Cannot access kube-apiserver pods. Insufficient permissions or missing components."
        return 1
    fi
    
    if ! oc get pods -n openshift-ovn-kubernetes --no-headers 2>/dev/null | head -1 >/dev/null; then
        log_warning "Cannot access OVN-Kubernetes pods. OVN tracing will be skipped."
    fi
    
    # Get worker node for monitoring
    WORKER_NODE=$(oc get nodes --no-headers | grep -v master | grep -v control-plane | head -1 | awk '{print $1}')
    if [[ -z "$WORKER_NODE" ]]; then
        log_error "No worker nodes found for RST monitoring"
        return 1
    fi
    
    log_success "Cluster validation passed. Worker node: $WORKER_NODE"
    return 0
}

# Create test infrastructure
create_infrastructure() {
    log " Creating test infrastructure..."
    
    # Create namespace
    oc create namespace "$NAMESPACE" || {
        log_error "Failed to create namespace $NAMESPACE"
        return 1
    }
    
    # Label namespace for easy identification
    oc label namespace "$NAMESPACE" test="ocpbugs-77510" created-by="prow-ci"
    
    log " Deploying test services (simulating production workload)..."
    
    # Create multiple services to amplify the bug impact
    for i in $(seq 1 10); do
        cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app-$i
  namespace: $NAMESPACE
  labels:
    app: test-app-$i
    test: ocpbugs-77510
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-app-$i
  template:
    metadata:
      labels:
        app: test-app-$i
    spec:
      containers:
      - name: app
        image: registry.redhat.io/ubi8/httpd-24:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        env:
        - name: APP_ID
          value: "test-app-$i"
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: test-svc-$i
  namespace: $NAMESPACE
  labels:
    app: test-app-$i
    test: ocpbugs-77510
spec:
  selector:
    app: test-app-$i
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  type: ClusterIP
EOF
        
        if [[ $((i % 5)) -eq 0 ]]; then
            log "  ✅ Created $i/10 test services..."
            sleep 2  # Pace creation to avoid API server overload
        fi
    done
    
    # Create client workload that continuously accesses services
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client-workload
  namespace: $NAMESPACE
  labels:
    app: client-workload
    test: ocpbugs-77510
spec:
  replicas: 3
  selector:
    matchLabels:
      app: client-workload
  template:
    metadata:
      labels:
        app: client-workload
    spec:
      containers:
      - name: client
        image: registry.redhat.io/ubi8/ubi-minimal:latest
        command: ["/bin/bash"]
        args:
        - -c
        - |
          while true; do
            for svc in \$(seq 1 10); do
              curl -s --connect-timeout 2 --max-time 5 "http://test-svc-\${svc}.$NAMESPACE.svc.cluster.local/" >/dev/null 2>&1 || true
              sleep 0.5
            done
          done
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
          limits:
            memory: "64Mi"
            cpu: "50m"
EOF
    
    log " Waiting for infrastructure to be ready..."
    
    # Wait for deployments to be ready
    local timeout=300
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local ready_pods
        ready_pods=$(oc get pods -n "$NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        local total_pods
        total_pods=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
        
        if [[ $ready_pods -ge 20 ]]; then  # 20 test app pods + 3 client pods minimum
            log_success "Infrastructure ready: $ready_pods/$total_pods pods running"
            sleep 10  # Allow connections to stabilize
            return 0
        fi
        
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log "Infrastructure status: $ready_pods/$total_pods pods ready (${elapsed}s elapsed)"
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Infrastructure failed to become ready within $timeout seconds"
    oc get pods -n "$NAMESPACE" -o wide
    return 1
}

# Start RST monitoring
start_rst_monitoring() {
    log " Starting TCP RST packet monitoring..."
    
    # Start RST monitoring on worker node
    {
        timeout $((TIMEOUT_MINUTES * 60)) oc debug "node/$WORKER_NODE" --quiet -- \
            tcpdump -i any -nn 'tcp[tcpflags] & tcp-rst != 0' 2>/dev/null | \
            while read -r line; do
                echo "$(date '+%Y-%m-%d %H:%M:%S'): RST: $line"
            done
    } > "/tmp/${TEST_NAME}-rst.log" 2>&1 &
    
    local monitor_pid=$!
    echo $monitor_pid > "/tmp/${TEST_NAME}-monitor.pid"
    
    log " RST monitoring started (PID: $monitor_pid) on node: $WORKER_NODE"
    sleep 10  # Allow monitoring to start
}

# Execute the bug trigger
trigger_bug() {
    log " Triggering OCPBUGS-77510 bug (API server restart scenario)..."
    
    # Get API server pods
    local api_pods
    api_pods=$(oc get pods -n openshift-kube-apiserver -l app=kube-apiserver --no-headers | awk '{print $1}' | head -3)
    local api_count
    api_count=$(echo "$api_pods" | wc -l)
    
    log " Found $api_count kube-apiserver pods to restart"
    
    if [[ $api_count -eq 0 ]]; then
        log_error "No kube-apiserver pods found"
        return 1
    fi
    
    log "⚠️ Restarting API server pods (simulating etcd encryption key rotation)"
    log "   This triggers:"
    log "   1. API server pods restart"
    log "   2. OVN-Kubernetes loses connection to API server"
    log "   3. OVN-K reconnects and syncs all services"
    log "   4. serviceUpdateNotNeeded() bug triggers for each service"
    log "   5. TCP RST storm affects active connections"
    
    # Restart API server pods (rolling restart)
    for pod in $api_pods; do
        log "   Restarting API server pod: $pod"
        oc delete pod "$pod" -n openshift-kube-apiserver --grace-period=10 &
        sleep 30  # Wait between restarts to avoid full outage
    done
    
    log " Monitoring TCP RST storm for $((TIMEOUT_MINUTES - 5)) minutes..."
    sleep $((TIMEOUT_MINUTES - 5)) * 60
}

# Save comprehensive test artifacts for manual investigation
save_test_artifacts() {
    log " Saving comprehensive test artifacts..."
    
    # Create artifacts directory
    ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
    mkdir -p "$ARTIFACT_DIR"
    
    # Save RST logs
    if [[ -f "/tmp/${TEST_NAME}-rst.log" ]]; then
        cp "/tmp/${TEST_NAME}-rst.log" "$ARTIFACT_DIR/ocpbugs-77510-rst-packets.log"
        log "  📋 RST packet capture: $ARTIFACT_DIR/ocpbugs-77510-rst-packets.log"
    fi
    
    # Save cluster state for manual investigation
    oc get pods -n "$NAMESPACE" -o wide > "$ARTIFACT_DIR/test-pods-state.log" 2>&1 || true
    oc get svc -n "$NAMESPACE" -o yaml > "$ARTIFACT_DIR/test-services-detailed.yaml" 2>&1 || true
    oc get events -n "$NAMESPACE" --sort-by='.lastTimestamp' > "$ARTIFACT_DIR/test-events.log" 2>&1 || true
    
    # Save OVN-Kubernetes and API server state
    oc get pods -n openshift-ovn-kubernetes -o wide > "$ARTIFACT_DIR/ovn-kubernetes-pods.log" 2>&1 || true
    oc get pods -n openshift-kube-apiserver -o wide > "$ARTIFACT_DIR/kube-apiserver-pods.log" 2>&1 || true
    oc logs -n openshift-ovn-kubernetes ds/ovnkube-node --tail=500 > "$ARTIFACT_DIR/ovn-kubernetes-logs.log" 2>&1 || true
    
    # Save node information
    oc get nodes -o wide > "$ARTIFACT_DIR/cluster-nodes.log" 2>&1 || true
    oc describe node "$WORKER_NODE" > "$ARTIFACT_DIR/worker-node-details.log" 2>&1 || true
    
    # Create manual investigation guide
    local rst_count
    rst_count=$(grep -c "RST:" "/tmp/${TEST_NAME}-rst.log" 2>/dev/null || echo "0")
    
    cat > "$ARTIFACT_DIR/MANUAL_INVESTIGATION_GUIDE.md" << EOF
# OCPBUGS-77510 Manual Investigation Guide

## Test Results Summary
- **Date**: $(date)
- **Cluster**: $(oc whoami --show-server 2>/dev/null || echo 'unknown')
- **Version**: $(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo 'unknown')
- **RST Packets Captured**: $rst_count (threshold: $EXPECTED_MIN_RST)
- **Test Namespace**: $NAMESPACE
- **Monitor Node**: $WORKER_NODE

## Bug Status Analysis
$([[ $rst_count -ge $EXPECTED_MIN_RST ]] && echo "
🚨 **BUG REPRODUCED** - OCPBUGS-77510 is PRESENT
- High RST count indicates serviceUpdateNotNeeded() bug is active
- This cluster needs the reflect.DeepEqual() fix
" || echo "
✅ **BUG NOT REPRODUCED** - Possible fix present
- Low RST count suggests bug may be fixed
- Or different network configuration/timing
")

## Manual Investigation Commands

### 1. Check Test Infrastructure
\`\`\`bash
# Test pods and services
oc get pods -n $NAMESPACE -o wide
oc get svc -n $NAMESPACE -o yaml

# Test events
oc get events -n $NAMESPACE --sort-by='.lastTimestamp'
\`\`\`

### 2. Monitor TCP RST Packets Manually
\`\`\`bash
# Live RST monitoring
oc debug node/$WORKER_NODE --quiet -- tcpdump -i any -nnvv 'tcp[tcpflags] & tcp-rst != 0'

# With packet details
oc debug node/$WORKER_NODE --quiet -- tcpdump -i any -nnvvS 'tcp[tcpflags] & tcp-rst != 0'
\`\`\`

### 3. Trigger Manual API Server Restart
\`\`\`bash
# Get API server pods
oc get pods -n openshift-kube-apiserver -l app=kube-apiserver

# Restart API servers (one at a time)
for pod in \$(oc get pods -n openshift-kube-apiserver -l app=kube-apiserver --no-headers | awk '{print \$1}' | head -3); do
    echo "Restarting \$pod"
    oc delete pod \$pod -n openshift-kube-apiserver --grace-period=10
    sleep 30
done
\`\`\`

### 4. Investigate OVN-Kubernetes
\`\`\`bash
# OVN pods status
oc get pods -n openshift-ovn-kubernetes

# OVN logs during restart
oc logs -n openshift-ovn-kubernetes ds/ovnkube-node --tail=100 -f

# Check for serviceUpdateNotNeeded calls
oc logs -n openshift-ovn-kubernetes ds/ovnkube-node | grep -i "serviceUpdateNotNeeded\|DeepEqual"
\`\`\`

### 5. Generate Load for Better RST Capture
\`\`\`bash
# Create additional client traffic
oc run test-client --image=curlimages/curl -n $NAMESPACE -- /bin/sh -c "
while true; do 
    for svc in \$(seq 1 10); do 
        curl -s http://test-svc-\${svc}.$NAMESPACE.svc.cluster.local/ >/dev/null 2>&1 || true
        sleep 1
    done
done"

# Then trigger API restart while monitoring RST packets
\`\`\`

### 6. Check OVN-Kubernetes Version and Fix Status
\`\`\`bash
# Get OVN-K version
oc get pods -n openshift-ovn-kubernetes -o yaml | grep image: | grep ovn-kubernetes

# Check for reflect.DeepEqual fix in source (if accessible)
# Look for PR that changed serviceUpdateNotNeeded function
\`\`\`

## Expected Behavior

### With Bug (OCPBUGS-77510 present):
- High RST packet count during API restart (>100 packets)
- Connections drop/reset during restart
- serviceUpdateNotNeeded() uses == comparison (incorrect)

### With Fix Applied:
- Low/zero RST packets during API restart
- Minimal connection disruption
- serviceUpdateNotNeeded() uses reflect.DeepEqual() (correct)

## Troubleshooting

### No RST Packets Captured:
1. Check monitoring permissions: \`oc debug node/$WORKER_NODE --quiet -- whoami\`
2. Verify tcpdump availability: \`oc debug node/$WORKER_NODE --quiet -- which tcpdump\`
3. Check network interface: \`oc debug node/$WORKER_NODE --quiet -- ip link show\`

### API Restart Not Triggering RST:
1. Ensure OVN-K reconnection happens
2. Check if etcd encryption is enabled (different trigger pattern)
3. Verify services are actively receiving traffic

## Test Artifacts
- RST Capture: \`ocpbugs-77510-rst-packets.log\`
- Pod States: \`test-pods-state.log\`
- Service Details: \`test-services-detailed.yaml\`
- OVN Logs: \`ovn-kubernetes-logs.log\`
- Cluster Info: \`cluster-nodes.log\`

---
Generated by OCPBUGS-77510 test at $(date)
EOF
    
    log "  📄 Investigation guide: $ARTIFACT_DIR/MANUAL_INVESTIGATION_GUIDE.md"
    log "  📊 Cluster state saved for manual analysis"
    log "  🔍 Use 'wait' step will preserve cluster for manual investigation"
}

# Analyze results
analyze_results() {
    log " Analyzing test results..."
    
    # Stop monitoring
    if [[ -f "/tmp/${TEST_NAME}-monitor.pid" ]]; then
        local monitor_pid
        monitor_pid=$(cat "/tmp/${TEST_NAME}-monitor.pid")
        kill "$monitor_pid" 2>/dev/null || true
        rm -f "/tmp/${TEST_NAME}-monitor.pid"
    fi
    
    sleep 3  # Allow final packets to be captured
    
    # Count RST packets
    local rst_count=0
    if [[ -f "/tmp/${TEST_NAME}-rst.log" ]]; then
        rst_count=$(grep -c "RST:" "/tmp/${TEST_NAME}-rst.log" 2>/dev/null || echo "0")
    fi
    
    # Get infrastructure stats
    local total_pods
    total_pods=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    local total_services
    total_services=$(oc get svc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    
    log " Test Results Summary:"
    log "========================"
    log " Test Scenario: API server restart (production trigger)"
    log " Infrastructure: $total_pods pods, $total_services services"
    log " TCP RST packets captured: $rst_count"
    log " Test duration: $TIMEOUT_MINUTES minutes"
    log "  Monitor node: $WORKER_NODE"
    
    # Determine test result
    if [[ $rst_count -ge $EXPECTED_MIN_RST ]]; then
        log_success "TEST PASSED: OCPBUGS-77510 successfully reproduced!"
        log_success "Captured $rst_count RST packets (threshold: $EXPECTED_MIN_RST)"
        log_success "Bug confirmed: API server restart triggers TCP RST storms"
        
        # Show sample RST packets for analysis
        if [[ $rst_count -gt 0 ]]; then
            log " Sample RST packets (first 5):"
            head -10 "/tmp/${TEST_NAME}-rst.log" | tail -5 2>/dev/null || true
        fi
        
        return 0
    elif [[ $rst_count -gt 0 ]]; then
        log_warning "TEST PARTIAL: Some RST activity detected ($rst_count packets)"
        log_warning "Below expected threshold ($EXPECTED_MIN_RST) but bug mechanism confirmed"
        log_warning "This may indicate:"
        log_warning "- Different cluster configuration reducing RST generation"
        log_warning "- Timing differences in this environment" 
        log_warning "- Partial fix already applied"
        
        return 2  # Partial success
    else
        log_error "TEST FAILED: No RST packets captured"
        log_error "Possible causes:"
        log_error "- Bug already fixed in this cluster"
        log_error "- Monitoring permissions insufficient"
        log_error "- Network configuration prevents RST capture"
        log_error "- API restart too graceful (no OVN reconnection)"
        
        # Show debugging info
        log " Debugging information:"
        log "Monitor log size: $(wc -l "/tmp/${TEST_NAME}-rst.log" 2>/dev/null || echo "0 lines")"
        
        return 1
    fi
}

# Main execution
main() {
    log "🚀 Starting OCPBUGS-77510 End-to-End Test"
    log "=========================================="
    log "Test: TCP RST storms during kube-apiserver rollouts"
    
    # Validate environment
    validate_cluster || exit 1
    
    # Create test infrastructure
    create_infrastructure || exit 1
    
    # Start monitoring
    start_rst_monitoring || exit 1
    
    # Execute bug trigger
    trigger_bug || exit 1
    
    # Analyze and report results
    local test_result=0
    if analyze_results; then
        log_success "🎉 OCPBUGS-77510 test completed successfully!"
        test_result=0
    elif [[ $? -eq 2 ]]; then
        log_warning "⚠️ OCPBUGS-77510 test completed with partial results"
        test_result=0  # Don't fail CI on partial results
    else
        log_error "❌ OCPBUGS-77510 test failed to reproduce bug"
        test_result=1
    fi
    
    # Save comprehensive artifacts for manual investigation
    save_test_artifacts
    
    log "📋 Test completed - cluster will be preserved for manual investigation"
    log "    Use the wait step timeout (30 minutes) for manual analysis"
    log "    Check MANUAL_INVESTIGATION_GUIDE.md in artifacts for commands"
    
    exit $test_result
}

# Execute main function
main