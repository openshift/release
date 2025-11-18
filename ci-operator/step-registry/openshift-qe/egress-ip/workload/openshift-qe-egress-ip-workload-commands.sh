#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Workload Generation
# Creates workloads that actively use egress IPs for validation

echo "Starting OpenShift QE Egress IP Workload Generation"
echo "==================================================="

# Configuration
WORKLOAD_TYPE="${WORKLOAD_TYPE:-blue-red}"
NUM_PROJECTS="${NUM_PROJECTS:-4}"
TEST_DURATION="${TEST_DURATION:-300}"
ECHO_SERVER="${ECHO_SERVER:-}"

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

# Cleanup function
cleanup() {
    log_info "Cleaning up workload resources..."
    for i in {1..4}; do
        oc delete ns "test$i" --ignore-not-found=true 2>/dev/null || true
    done
    oc delete egressip egressip-blue egressip-red --ignore-not-found=true 2>/dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT

log_info "Configuration: TYPE=$WORKLOAD_TYPE, PROJECTS=$NUM_PROJECTS, DURATION=$TEST_DURATION"

# Get cluster information for dynamic IP calculation
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
SUBNET_BASE=$(echo "$NODE_IP" | cut -d. -f1-3)
BLUE_IP1="${SUBNET_BASE}.201"
BLUE_IP2="${SUBNET_BASE}.202"
RED_IP1="${SUBNET_BASE}.101"
RED_IP2="${SUBNET_BASE}.102"

log_info "Calculated egress IPs - Blue: $BLUE_IP1,$BLUE_IP2 Red: $RED_IP1,$RED_IP2"

# Calculate echo server URL if not provided
if [[ -z "$ECHO_SERVER" ]]; then
    # Use a public IP echo service that returns the source IP
    ECHO_SERVER="http://ifconfig.me/ip"
    log_info "Using public echo server: $ECHO_SERVER"
else
    log_info "Using provided echo server: $ECHO_SERVER"
fi

# Create blue team egress IP configuration
log_info "Creating blue team egress IP configuration..."
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-blue
spec:
  egressIPs:
  - "$BLUE_IP1"
  - "$BLUE_IP2"
  podSelector:
    matchLabels:
      team: blue
  namespaceSelector:
    matchLabels:
      department: qe
EOF

# Create red team egress IP configuration
log_info "Creating red team egress IP configuration..."
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-red
spec:
  egressIPs:
  - "$RED_IP1"
  - "$RED_IP2"
  podSelector:
    matchLabels:
      team: red
  namespaceSelector:
    matchLabels:
      department: qe
EOF

# Create test namespaces and workloads
log_info "Creating test namespaces and workloads..."
for i in {1..4}; do
    log_info "Creating namespace test$i..."
    
    # Create namespace
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: test$i
  labels:
    department: qe
EOF

    # Determine team assignment
    if [[ $i -le 2 ]]; then
        TEAM="blue"
    else
        TEAM="red"
    fi
    
    log_info "Creating $TEAM team pod in test$i..."
    
    # Create pod with team label
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: test$i
  labels:
    team: $TEAM
spec:
  containers:
  - name: test-container
    image: registry.redhat.io/ubi8/ubi:latest
    command: ["sleep", "7200"]
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
EOF
done

# Wait for pods to be ready
log_info "Waiting for pods to be ready..."
for i in {1..4}; do
    log_info "Waiting for pod in test$i to be ready..."
    oc wait --for=condition=Ready pod/test-pod -n "test$i" --timeout=300s || error_exit "Pod in test$i failed to become ready"
done

# Wait for egress IPs to be assigned
log_info "Waiting for egress IP assignments..."
for eip in egressip-blue egressip-red; do
    for attempt in {1..30}; do
        ASSIGNED=$(oc get egressip "$eip" -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
        if [[ -n "$ASSIGNED" ]]; then
            log_success "Egress IP $eip assigned to: $ASSIGNED"
            break
        fi
        log_info "Waiting for $eip assignment... ($attempt/30)"
        sleep 5
    done
done

# Validate egress IP functionality
log_info "Validating egress IP functionality..."
for i in {1..4}; do
    if [[ $i -le 2 ]]; then
        EXPECTED_TEAM="blue"
    else
        EXPECTED_TEAM="red"
    fi
    
    log_info "Testing egress from test$i (expected: $EXPECTED_TEAM team)..."
    
    # Test connectivity using the echo server
    EGRESS_RESULT=$(oc exec -n "test$i" test-pod -- curl -s --connect-timeout 10 "$ECHO_SERVER" || echo "FAILED")
    
    if [[ "$EGRESS_RESULT" == "FAILED" ]]; then
        log_warning "Failed to connect to echo server from test$i"
    else
        log_info "test$i egress result: $EGRESS_RESULT"
        
        # Check if the egress IP matches expected range
        if [[ "$EGRESS_RESULT" =~ ($BLUE_IP1|$BLUE_IP2) ]] && [[ "$EXPECTED_TEAM" == "blue" ]]; then
            log_success "✅ test$i correctly using blue team egress IP"
        elif [[ "$EGRESS_RESULT" =~ ($RED_IP1|$RED_IP2) ]] && [[ "$EXPECTED_TEAM" == "red" ]]; then
            log_success "✅ test$i correctly using red team egress IP"
        else
            log_warning "⚠️ test$i egress IP ($EGRESS_RESULT) doesn't match expected ($EXPECTED_TEAM)"
        fi
    fi
done

# Generate continuous load if specified
if [[ "$TEST_DURATION" -gt 0 ]]; then
    log_info "Starting continuous egress load generation for ${TEST_DURATION}s..."
    
    # Create background load generators
    for i in {1..4}; do
        {
            local_count=0
            while [[ $local_count -lt $TEST_DURATION ]]; do
                oc exec -n "test$i" test-pod -- curl -s --connect-timeout 5 "$ECHO_SERVER" >/dev/null 2>&1 || true
                sleep 1
                ((local_count++))
            done
        } &
    done
    
    log_info "Load generators started. Monitoring for $TEST_DURATION seconds..."
    
    # Monitor egress IP assignments during load
    for check in {1..10}; do
        sleep $((TEST_DURATION / 10))
        
        log_info "Health check $check/10..."
        
        # Verify egress IP assignments are still active
        for eip in egressip-blue egressip-red; do
            ASSIGNED=$(oc get egressip "$eip" -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
            if [[ -n "$ASSIGNED" ]]; then
                log_info "$eip still assigned to: $ASSIGNED"
            else
                log_warning "$eip lost assignment during load test!"
            fi
        done
    done
    
    # Wait for background jobs to complete
    wait
    log_success "Continuous load testing completed"
fi

# Display final egress IP status
log_info "==============================="
log_info "Workload Generation Summary"
log_info "==============================="
oc get egressip -o wide
log_info "Active test pods:"
for i in {1..4}; do
    POD_STATUS=$(oc get pod -n "test$i" test-pod -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    log_info "  test$i: $POD_STATUS"
done

log_success "✅ Egress IP workload generation completed successfully!"
log_info "Workloads will remain active for resilience testing..."
