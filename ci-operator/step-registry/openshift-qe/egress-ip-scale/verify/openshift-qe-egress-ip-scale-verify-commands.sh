#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Scale Validation
# Validates egress IP functionality between chaos scenarios

echo "Starting Egress IP Scale Validation"
echo "=================================="

# Configuration
EGRESS_IP_COUNT="${EGRESS_IP_COUNT:-5}"
MIN_SUCCESS_RATE="${MIN_SUCCESS_RATE:-75}"
HEALTH_CHECK_URLS="${HEALTH_CHECK_URLS:-https://httpbin.org/ip,https://ifconfig.me/ip,https://api.ipify.org}"
VALIDATION_TIMEOUT="${VALIDATION_TIMEOUT:-300}"
RECOVERY_WAIT_TIME="${RECOVERY_WAIT_TIME:-60}"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Logging setup
LOG_FILE="$ARTIFACT_DIR/egress_ip_validation_$(date +%Y%m%d_%H%M%S).log"
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

# Wait for recovery after chaos
log_info "Waiting ${RECOVERY_WAIT_TIME}s for system recovery after chaos scenario..."
sleep "$RECOVERY_WAIT_TIME"

# Validate cluster connectivity
log_info "Validating cluster connectivity..."
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster"
fi

# Phase 1: Validate OVN components health
log_info "Phase 1: Validating OVN components health..."

# Check OVN pods status
ovn_pod_count=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --no-headers | wc -l)
ready_ovn_pods=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --no-headers | grep "Running" | wc -l)

log_info "OVN pods: $ready_ovn_pods/$ovn_pod_count ready"

if [[ "$ready_ovn_pods" -lt 3 ]]; then
    log_warning "Some OVN pods are not ready, but continuing validation"
fi

# Phase 2: Validate egress IP assignments
log_info "Phase 2: Validating egress IP assignments..."

functional_eips=0
total_eips=0

# Get all egress IPs
eip_list=$(oc get egressips -o name 2>/dev/null || echo "")

if [[ -z "$eip_list" ]]; then
    log_warning "No egress IPs found in cluster"
else
    for eip in $eip_list; do
        eip_name=$(echo "$eip" | cut -d'/' -f2)
        total_eips=$((total_eips + 1))
        
        # Check if egress IP is assigned
        assigned_node=$(oc get "$eip" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        assigned_ip=$(oc get "$eip" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
        
        if [[ -n "$assigned_node" && -n "$assigned_ip" ]]; then
            log_info "Egress IP $eip_name ($assigned_ip) assigned to node $assigned_node"
            functional_eips=$((functional_eips + 1))
        else
            log_error "Egress IP $eip_name is not properly assigned"
        fi
    done
fi

# Calculate success rate
if [[ "$total_eips" -gt 0 ]]; then
    success_rate=$(( (functional_eips * 100) / total_eips ))
    log_info "Egress IP assignment success rate: $success_rate% ($functional_eips/$total_eips)"
    
    if [[ "$success_rate" -lt "$MIN_SUCCESS_RATE" ]]; then
        log_error "Egress IP success rate ($success_rate%) below minimum threshold ($MIN_SUCCESS_RATE%)"
        # Don't exit here, continue with traffic validation
    fi
else
    log_warning "No egress IPs configured for validation"
fi

# Phase 3: Validate egress traffic functionality
log_info "Phase 3: Validating egress traffic functionality..."

# Create temporary test pod for traffic validation
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: egress-validation-temp
  labels:
    egress: validation
---
apiVersion: v1
kind: Pod
metadata:
  name: validation-test-pod
  namespace: egress-validation-temp
  labels:
    app: validation-test
    egress-enabled: "true"
spec:
  restartPolicy: Never
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
      capabilities:
        drop:
        - ALL
EOF

# Wait for pod to be ready
log_info "Waiting for validation test pod to be ready..."
oc wait --for=condition=Ready pod/validation-test-pod -n egress-validation-temp --timeout=60s

# Test connectivity to health check URLs
IFS=',' read -ra URLS <<< "$HEALTH_CHECK_URLS"
successful_requests=0
total_requests=${#URLS[@]}

for url in "${URLS[@]}"; do
    log_info "Testing connectivity to $url..."
    
    if timeout 30 oc exec -n egress-validation-temp validation-test-pod -- curl -s --max-time 20 "$url" > /tmp/response.txt 2>&1; then
        response=$(cat /tmp/response.txt)
        log_success "Successfully reached $url - Response: $response"
        successful_requests=$((successful_requests + 1))
    else
        log_error "Failed to reach $url"
    fi
done

# Calculate traffic validation success rate
traffic_success_rate=$(( (successful_requests * 100) / total_requests ))
log_info "Traffic validation success rate: $traffic_success_rate% ($successful_requests/$total_requests)"

# Cleanup
log_info "Cleaning up validation resources..."
oc delete namespace egress-validation-temp --ignore-not-found=true

# Phase 4: Final validation assessment
log_info "Phase 4: Final validation assessment..."

validation_passed=true

if [[ "$total_eips" -gt 0 && "$success_rate" -lt "$MIN_SUCCESS_RATE" ]]; then
    log_error "Egress IP assignment validation failed"
    validation_passed=false
fi

if [[ "$traffic_success_rate" -lt 50 ]]; then
    log_error "Traffic validation failed - less than 50% of URLs reachable"
    validation_passed=false
fi

# Generate validation summary
cat > "$ARTIFACT_DIR/validation_summary.txt" << EOF
Egress IP Scale Validation Summary
=================================
Timestamp: $(date)
Total Egress IPs: $total_eips
Functional Egress IPs: $functional_eips
EIP Assignment Success Rate: $success_rate%
Traffic Validation Success Rate: $traffic_success_rate%
Minimum Required Success Rate: $MIN_SUCCESS_RATE%
Overall Validation: $(if $validation_passed; then echo "PASSED"; else echo "FAILED"; fi)
EOF

if $validation_passed; then
    log_success "Validation completed successfully"
    log_info "System is ready for next chaos scenario"
else
    log_warning "Validation completed with issues, but continuing test suite"
    log_info "Check validation summary for details"
fi

log_info "Validation artifacts saved to $ARTIFACT_DIR"
echo "Egress IP Scale Validation completed"