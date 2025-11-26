#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Scale Tests
# Comprehensive validation of scaled egress IP functionality after chaos testing

echo "Starting OpenShift QE Egress IP Scale Tests"
echo "==========================================="

# Configuration
EGRESS_IP_COUNT="${EGRESS_IP_COUNT:-5}"
SCALE_TEST_WORKLOADS="${SCALE_TEST_WORKLOADS:-20}"
NAMESPACE="openshift-ovn-kubernetes"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Logging setup
LOG_FILE="$ARTIFACT_DIR/egress_ip_scale_test_$(date +%Y%m%d_%H%M%S).log"
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

# Validate cluster connectivity
log_info "Validating cluster connectivity after chaos testing..."
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster. Please check your kubeconfig."
fi

# Phase 1: Post-Chaos Egress IP Validation
log_info "==============================="
log_info "PHASE 1: Post-Chaos Egress IP Status Validation"
log_info "==============================="

log_info "Validating egress IP assignments after chaos testing..."

# Check all egress IP assignments
assigned_count=0
healthy_assignments=()

for ((i=1; i<=EGRESS_IP_COUNT; i++)); do
    eip_name="egressip-scale-$i"
    assigned_node=$(oc get egressip "$eip_name" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
    eip_address=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -n "$assigned_node" ]]; then
        assigned_count=$((assigned_count + 1))
        healthy_assignments+=("$eip_name:$assigned_node:$eip_address")
        log_success "✅ $eip_name -> $assigned_node ($eip_address)"
    else
        log_error "❌ $eip_name -> UNASSIGNED"
    fi
done

log_info "Egress IP assignment status: $assigned_count/$EGRESS_IP_COUNT assigned"

if [[ $assigned_count -eq 0 ]]; then
    error_exit "All egress IPs lost assignments - chaos testing caused complete failure"
elif [[ $assigned_count -lt $((EGRESS_IP_COUNT / 2)) ]]; then
    log_warning "⚠️  Significant egress IP assignment loss: $assigned_count/$EGRESS_IP_COUNT"
else
    log_success "✅ Majority of egress IPs maintained assignments: $assigned_count/$EGRESS_IP_COUNT"
fi

# Phase 2: Scale Workload Recovery Validation
log_info "==============================="
log_info "PHASE 2: Scale Workload Recovery Validation"
log_info "==============================="

log_info "Validating test workload recovery after chaos..."

ready_workloads=0
total_ready_replicas=0

for ((i=1; i<=EGRESS_IP_COUNT; i++)); do
    ns_name="egress-scale-test-$i"
    
    # Check if namespace still exists
    if ! oc get namespace "$ns_name" &>/dev/null; then
        log_warning "⚠️  Namespace $ns_name missing after chaos"
        continue
    fi
    
    # Check deployment status
    ready_replicas=$(oc get deployment -n "$ns_name" "test-workload-$i" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired_replicas=$(oc get deployment -n "$ns_name" "test-workload-$i" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "4")
    
    total_ready_replicas=$((total_ready_replicas + ready_replicas))
    
    if [[ "$ready_replicas" -eq "$desired_replicas" ]]; then
        ready_workloads=$((ready_workloads + 1))
        log_success "✅ Workload $i recovered: $ready_replicas/$desired_replicas replicas"
    else
        log_warning "⚠️  Workload $i partial recovery: $ready_replicas/$desired_replicas replicas"
    fi
done

log_info "Workload recovery status: $ready_workloads/$EGRESS_IP_COUNT workloads fully recovered"
log_info "Total ready replicas: $total_ready_replicas"

# Phase 3: OVN Scale Metrics Collection
log_info "==============================="
log_info "PHASE 3: Post-Chaos OVN Scale Metrics"
log_info "==============================="

log_info "Collecting OVN scale metrics after chaos testing..."

# Collect comprehensive NAT and policy metrics
total_nat_rules=0
total_lr_policies=0
ovn_pod_count=0

ovn_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$ovn_pods" ]]; then
    ovn_pod_count=$(echo $ovn_pods | wc -w)
    
    for pod in $ovn_pods; do
        # NAT rules for egress IP
        nat_count=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        total_nat_rules=$((total_nat_rules + nat_count))
        
        # Logical router policies
        lr_policy_count=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl lr-policy-list ovn_cluster_router | grep '100 ' | grep -v 1004 | wc -l" 2>/dev/null || echo "0")
        total_lr_policies=$((total_lr_policies + lr_policy_count))
    done
fi

log_info "OVN Scale Metrics:"
log_info "  - OVN Pods: $ovn_pod_count"
log_info "  - Total NAT Rules: $total_nat_rules"
log_info "  - Total LR Policies: $total_lr_policies"

# Phase 4: Scale Performance Impact Analysis
log_info "==============================="
log_info "PHASE 4: Scale Performance Impact Analysis"
log_info "==============================="

# Calculate performance impact ratios
if [[ -f "$ARTIFACT_DIR/scale_baseline_metrics.json" ]]; then
    baseline_nat=$(jq -r '.ovn_metrics.total_nat_rules' "$ARTIFACT_DIR/scale_baseline_metrics.json" 2>/dev/null || echo "0")
    baseline_workloads=$(jq -r '.cluster_config.ready_workloads' "$ARTIFACT_DIR/scale_baseline_metrics.json" 2>/dev/null || echo "0")
    
    nat_retention_rate="N/A"
    workload_retention_rate="N/A"
    
    if [[ "$baseline_nat" -gt 0 ]]; then
        nat_retention_rate=$(echo "scale=2; $total_nat_rules * 100 / $baseline_nat" | bc -l)
    fi
    
    if [[ "$baseline_workloads" -gt 0 ]]; then
        workload_retention_rate=$(echo "scale=2; $ready_workloads * 100 / $baseline_workloads" | bc -l)
    fi
    
    log_info "Performance Impact Analysis:"
    log_info "  - NAT Rule Retention: ${nat_retention_rate}%"
    log_info "  - Workload Retention: ${workload_retention_rate}%"
else
    log_warning "⚠️  Baseline metrics not found - cannot calculate retention rates"
fi

# Phase 5: Detailed Scale Test Results
log_info "==============================="
log_info "PHASE 5: Generate Scale Test Results"
log_info "==============================="

# Save comprehensive scale test results
cat > "$ARTIFACT_DIR/scale_test_results.json" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "test_type": "egress_ip_scale_post_chaos",
  "test_config": {
    "target_egress_ips": $EGRESS_IP_COUNT,
    "target_workloads": $EGRESS_IP_COUNT,
    "chaos_testing_completed": true
  },
  "egress_ip_status": {
    "assigned_count": $assigned_count,
    "assignment_rate": $(echo "scale=2; $assigned_count * 100 / $EGRESS_IP_COUNT" | bc -l),
    "healthy_assignments": $(printf '%s\n' "${healthy_assignments[@]}" | jq -R . | jq -s .)
  },
  "workload_recovery": {
    "ready_workloads": $ready_workloads,
    "total_ready_replicas": $total_ready_replicas,
    "recovery_rate": $(echo "scale=2; $ready_workloads * 100 / $EGRESS_IP_COUNT" | bc -l)
  },
  "ovn_scale_metrics": {
    "ovn_pods": $ovn_pod_count,
    "total_nat_rules": $total_nat_rules,
    "total_lr_policies": $total_lr_policies
  },
  "test_verdict": "$(if [[ $assigned_count -ge $((EGRESS_IP_COUNT * 3 / 4)) ]] && [[ $ready_workloads -ge $((EGRESS_IP_COUNT / 2)) ]]; then echo "PASS"; else echo "PARTIAL"; fi)"
}
EOF

# Phase 6: Final Scale Test Summary
log_info "==============================="
log_info "FINAL SCALE TEST SUMMARY"
log_info "==============================="

log_success "🚀 Scale egress IP chaos testing completed!"
log_info "Test Configuration:"
log_info "  - Target Egress IPs: $EGRESS_IP_COUNT"
log_info "  - Assigned Egress IPs: $assigned_count ($(echo "scale=0; $assigned_count * 100 / $EGRESS_IP_COUNT" | bc -l)%)"
log_info "  - Recovered Workloads: $ready_workloads ($(echo "scale=0; $ready_workloads * 100 / $EGRESS_IP_COUNT" | bc -l)%)"
log_info "  - OVN NAT Rules: $total_nat_rules"
log_info "  - Test Duration: $SECONDS seconds"
log_info "  - Results File: $ARTIFACT_DIR/scale_test_results.json"

# Display final egress IP status
log_info "Final egress IP status:"
oc get egressip -o wide

# Test verdict
if [[ $assigned_count -ge $((EGRESS_IP_COUNT * 3 / 4)) ]] && [[ $ready_workloads -ge $((EGRESS_IP_COUNT / 2)) ]]; then
    log_success "🎉 SCALE TEST VERDICT: PASS - Egress IP resilience validated at scale!"
    exit 0
elif [[ $assigned_count -ge $((EGRESS_IP_COUNT / 2)) ]]; then
    log_warning "⚠️  SCALE TEST VERDICT: PARTIAL - Some degradation detected but core functionality maintained"
    exit 0
else
    error_exit "❌ SCALE TEST VERDICT: FAIL - Significant egress IP functionality loss"
fi