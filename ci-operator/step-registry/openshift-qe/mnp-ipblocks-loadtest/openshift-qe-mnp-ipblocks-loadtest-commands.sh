#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# MNP-76500 ACL Explosion Reproduction Test
# ==========================================
# Reproduces customer scenario that caused OVN database explosion:
# - 385 MultiNetworkPolicies with 450 CIDR blocks each
# - 1400 pods across 14 workers (100 pods per worker)
# - Results in 1.57M ACLs causing system instability

echo "🧪 Starting MNP-76500 ACL Explosion Reproduction Test"
echo "========================================================"

# Configuration from environment variables
MNP_TOTAL_PODS="${MNP_TOTAL_PODS:-1400}"
MNP_POLICY_COUNT="${MNP_POLICY_COUNT:-385}"
MNP_CIDRS_PER_POLICY="${MNP_CIDRS_PER_POLICY:-450}"

echo "📊 Test Configuration:"
echo "  - Total Pods: $MNP_TOTAL_PODS"
echo "  - Policy Count: $MNP_POLICY_COUNT"
echo "  - CIDRs per Policy: $MNP_CIDRS_PER_POLICY"
echo "  - Expected ipBlocks: $((MNP_POLICY_COUNT * MNP_CIDRS_PER_POLICY)) (173,250 in customer case)"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Logging setup with timestamps
LOG_FILE="$ARTIFACT_DIR/mnp_acl_explosion_test.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Logging functions
log_info() { echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $1"; }
log_success() { echo "$(date +'%Y-%m-%d %H:%M:%S') [SUCCESS] $1"; }
log_warning() { echo "$(date +'%Y-%m-%d %H:%M:%S') [WARNING] $1"; }
log_error() { echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $1"; }

# Install required tools
log_info "📦 Installing required tools..."
yum install -y git wget curl jq bc

# Clone Liquan's MNP load test tool
log_info "📥 Cloning MNP load test tool..."
cd /tmp
git clone https://github.com/liqcui/mnp_loadtest.git
cd mnp_loadtest

# Verify cluster readiness
log_info "🔍 Verifying cluster readiness..."
worker_count=$(oc get nodes -l node-role.kubernetes.io/worker= --no-headers | wc -l)
log_info "Worker nodes available: $worker_count"

if [[ $worker_count -lt 14 ]]; then
    log_error "❌ Insufficient workers: $worker_count < 14 required"
    exit 1
fi

log_success "✅ Cluster ready with $worker_count workers"

# Baseline measurements
log_info "📏 Taking baseline measurements..."

# Function to get OVN database size
get_ovn_db_size() {
    local ovn_master_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "$ovn_master_pod" ]]; then
        oc exec -n openshift-ovn-kubernetes "$ovn_master_pod" -c ovnkube-master -- du -sh /etc/ovn/ 2>/dev/null | cut -f1 || echo "unknown"
    else
        echo "unknown"
    fi
}

# Function to count ACLs
count_acls() {
    local ovn_master_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "$ovn_master_pod" ]]; then
        oc exec -n openshift-ovn-kubernetes "$ovn_master_pod" -c ovnkube-master -- ovn-nbctl list acl 2>/dev/null | grep -c "^_uuid" || echo "0"
    else
        echo "0"
    fi
}

# Function to monitor logical flow recomputation time
monitor_flow_recomputation() {
    local ovn_master_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "$ovn_master_pod" ]]; then
        # Check ovn-northd logs for recomputation time indicators
        oc logs -n openshift-ovn-kubernetes "$ovn_master_pod" -c ovnkube-master --tail=50 2>/dev/null | grep -E "(recompute|logical.*flow)" | tail -5 || echo "No recomputation logs found"
    fi
}

# Baseline measurements
baseline_db_size=$(get_ovn_db_size)
baseline_acl_count=$(count_acls)

log_info "📊 Baseline Measurements:"
log_info "  - OVN DB Size: $baseline_db_size"
log_info "  - ACL Count: $baseline_acl_count"

# Save baseline to artifacts
cat > "$ARTIFACT_DIR/baseline_metrics.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "baseline_db_size": "$baseline_db_size",
    "baseline_acl_count": $baseline_acl_count,
    "worker_count": $worker_count,
    "test_config": {
        "total_pods": $MNP_TOTAL_PODS,
        "policy_count": $MNP_POLICY_COUNT,
        "cidrs_per_policy": $MNP_CIDRS_PER_POLICY,
        "expected_ipblocks": $((MNP_POLICY_COUNT * MNP_CIDRS_PER_POLICY))
    }
}
EOF

# Execute the customer-scale MNP load test
log_info "🚀 Starting customer-scale MNP load test reproduction..."
log_info "Command: ./generate-customer-scale-pods.sh --total-pods $MNP_TOTAL_PODS --policy-count $MNP_POLICY_COUNT --cidrs-per-policy $MNP_CIDRS_PER_POLICY --apply"

start_time=$(date +%s)

# Make the script executable if it isn't
chmod +x generate-customer-scale-pods.sh

# Execute the load test with comprehensive monitoring
if ./generate-customer-scale-pods.sh --total-pods "$MNP_TOTAL_PODS" --policy-count "$MNP_POLICY_COUNT" --cidrs-per-policy "$MNP_CIDRS_PER_POLICY" --apply; then
    log_success "✅ MNP load test execution completed"
else
    log_error "❌ MNP load test execution failed"
    # Don't exit immediately - we want to collect metrics even if it fails
fi

end_time=$(date +%s)
execution_duration=$((end_time - start_time))

log_info "⏱️  Test execution time: ${execution_duration} seconds"

# Post-test measurements
log_info "📊 Collecting post-test measurements..."

post_db_size=$(get_ovn_db_size)
post_acl_count=$(count_acls)

log_info "📈 Post-Test Measurements:"
log_info "  - OVN DB Size: $post_db_size (was: $baseline_db_size)"
log_info "  - ACL Count: $post_acl_count (was: $baseline_acl_count)"

# Calculate ACL increase
if [[ "$baseline_acl_count" =~ ^[0-9]+$ ]] && [[ "$post_acl_count" =~ ^[0-9]+$ ]]; then
    acl_increase=$((post_acl_count - baseline_acl_count))
    log_info "  - ACL Increase: $acl_increase ACLs added"
    
    # Check for ACL explosion threshold (customer had 1.57M ACLs)
    acl_explosion_threshold=1000000  # 1M ACLs
    if [[ $post_acl_count -gt $acl_explosion_threshold ]]; then
        log_warning "⚠️  ACL EXPLOSION DETECTED: $post_acl_count > $acl_explosion_threshold (threshold)"
        log_warning "   This reproduces the customer's MNP-76500 issue!"
    elif [[ $acl_increase -gt 100000 ]]; then
        log_warning "⚠️  Significant ACL increase detected: $acl_increase new ACLs"
    else
        log_success "✅ ACL count within reasonable limits"
    fi
else
    log_warning "⚠️  Unable to calculate ACL increase (non-numeric values)"
    acl_increase="unknown"
fi

# Monitor logical flow recomputation performance
log_info "🔍 Checking logical flow recomputation performance..."
monitor_flow_recomputation

# Collect detailed cluster state
log_info "📋 Collecting detailed cluster state..."

# MultiNetworkPolicy status
mnp_count=$(oc get multinetworkpolicy -A --no-headers 2>/dev/null | wc -l || echo "0")
log_info "MultiNetworkPolicies created: $mnp_count"

# Pod distribution across workers
log_info "📊 Pod distribution across workers:"
oc get pods -A --no-headers -o custom-columns=NODE:.spec.nodeName 2>/dev/null | grep -E "worker|compute" | sort | uniq -c | head -20

# OVN pod status
log_info "🔍 OVN pod status:"
oc get pods -n openshift-ovn-kubernetes -o wide

# Check for any OVN pod restarts/crashes
ovn_restarts=$(oc get pods -n openshift-ovn-kubernetes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].restartCount}{"\n"}{end}' | awk '{sum+=$2} END {print sum+0}')
log_info "Total OVN pod restarts: $ovn_restarts"

if [[ $ovn_restarts -gt 0 ]]; then
    log_warning "⚠️  OVN pod restarts detected: $ovn_restarts"
    log_warning "   This may indicate system instability from ACL explosion"
fi

# Save comprehensive test results
cat > "$ARTIFACT_DIR/test_results.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "test_duration_seconds": $execution_duration,
    "reproduction_status": "completed",
    "baseline_metrics": {
        "db_size": "$baseline_db_size",
        "acl_count": $baseline_acl_count
    },
    "post_test_metrics": {
        "db_size": "$post_db_size",
        "acl_count": $post_acl_count,
        "acl_increase": "$acl_increase"
    },
    "cluster_state": {
        "worker_count": $worker_count,
        "mnp_count": $mnp_count,
        "ovn_pod_restarts": $ovn_restarts
    },
    "test_config": {
        "total_pods": $MNP_TOTAL_PODS,
        "policy_count": $MNP_POLICY_COUNT,
        "cidrs_per_policy": $MNP_CIDRS_PER_POLICY,
        "expected_ipblocks": $((MNP_POLICY_COUNT * MNP_CIDRS_PER_POLICY))
    },
    "thresholds": {
        "acl_explosion_threshold": $acl_explosion_threshold,
        "acl_explosion_detected": $(if [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]]; then echo "true"; else echo "false"; fi)
    }
}
EOF

# Generate summary report
log_info "📄 Generating test summary report..."

cat > "$ARTIFACT_DIR/MNP-76500_test_summary.md" << EOF
# MNP-76500 ACL Explosion Reproduction Test Results

## Test Configuration
- **Customer Scenario**: 385 MultiNetworkPolicies × 450 CIDR blocks = 173,250 ipBlocks
- **Test Parameters**: 
  - Total Pods: $MNP_TOTAL_PODS
  - Policy Count: $MNP_POLICY_COUNT  
  - CIDRs per Policy: $MNP_CIDRS_PER_POLICY
  - Calculated ipBlocks: $((MNP_POLICY_COUNT * MNP_CIDRS_PER_POLICY))

## Results Summary
- **Test Duration**: ${execution_duration} seconds
- **Worker Nodes**: $worker_count
- **MultiNetworkPolicies Created**: $mnp_count

## Performance Impact
### OVN Database Growth
- **Before**: $baseline_db_size
- **After**: $post_db_size

### ACL Count Analysis  
- **Baseline ACLs**: $baseline_acl_count
- **Post-Test ACLs**: $post_acl_count
- **ACL Increase**: $acl_increase
- **ACL Explosion Threshold**: $acl_explosion_threshold
- **Explosion Detected**: $(if [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]]; then echo "🔴 YES - Customer issue reproduced!"; else echo "🟢 No"; fi)

## System Stability
- **OVN Pod Restarts**: $ovn_restarts $(if [[ $ovn_restarts -gt 0 ]]; then echo "(⚠️  Instability detected)"; else echo "(✅ Stable)"; fi)

## Customer Issue Reproduction Status
$(if [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]]; then 
    echo "🎯 **CUSTOMER ISSUE SUCCESSFULLY REPRODUCED**"
    echo "- ACL count exceeded 1M threshold ($post_acl_count ACLs)"
    echo "- This matches the customer's MNP-76500 scenario"
    echo "- System likely experiencing performance degradation"
else
    echo "ℹ️  **Customer issue not fully reproduced**"
    echo "- ACL count below explosion threshold"
    echo "- May need larger scale or different parameters"
fi)

## Next Steps
1. Monitor OVN logical flow recomputation times
2. Check for pod creation/scheduling delays  
3. Validate fix effectiveness with consolidated ipBlock ACLs
4. Performance comparison before/after optimization

---
*Generated on $(date) by MNP-76500 reproduction test*
EOF

# Final status
if [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]]; then
    log_success "🎯 MNP-76500 CUSTOMER ISSUE SUCCESSFULLY REPRODUCED!"
    log_success "   ACL Explosion detected: $post_acl_count ACLs > $acl_explosion_threshold threshold"
    log_success "   This validates the customer's reported scenario"
else
    log_info "ℹ️  Test completed but customer ACL explosion not reproduced"
    log_info "   ACL count: $post_acl_count (threshold: $acl_explosion_threshold)"
fi

log_info "📁 Test artifacts saved to: $ARTIFACT_DIR"
log_info "📄 Summary report: $ARTIFACT_DIR/MNP-76500_test_summary.md"
log_info "📊 Detailed results: $ARTIFACT_DIR/test_results.json"

echo "=========================================================="
echo "🏁 MNP-76500 ACL Explosion Reproduction Test Completed"
echo "=========================================================="