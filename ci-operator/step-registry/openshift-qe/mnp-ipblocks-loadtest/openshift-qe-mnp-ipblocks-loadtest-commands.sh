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

# Create embedded verification script for PR #2978 validation
log_info "🔧 Creating PR #2978 verification script..."
cat > /tmp/verify-pr2978-fix.sh << 'VERIFY_EOF'
#!/bin/bash

# PR #2978 MNP ipBlock Consolidation Fix Verification Script
# Embedded in CI to validate the fix is working during test execution

set -e

echo "=== PR #2978 MNP ipBlock Consolidation Fix Verification ==="
echo "Date: $(date)"
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'Not connected')"
echo

# Logging functions
log_info() { echo "$(date +'%Y-%m-%d %H:%M:%S') [VERIFY] $1"; }
log_success() { echo "$(date +'%Y-%m-%d %H:%M:%S') [VERIFY-SUCCESS] $1"; }
log_warning() { echo "$(date +'%Y-%m-%d %H:%M:%S') [VERIFY-WARNING] $1"; }
log_error() { echo "$(date +'%Y-%m-%d %H:%M:%S') [VERIFY-ERROR] $1"; }

# 1. Check cluster version and build date
log_info "=== 1. Cluster Version Check ==="
CLUSTER_VERSION=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "Unknown")
echo "Cluster Version: $CLUSTER_VERSION"

# Extract build date from version string
BUILD_DATE=$(echo $CLUSTER_VERSION | grep -o '2026-[0-9][0-9]-[0-9][0-9]' || echo "Unknown")
echo "Build Date: $BUILD_DATE"

# Check if build is after PR merge date
PR_MERGE_DATE="2026-02-20"
if [[ "$BUILD_DATE" > "$PR_MERGE_DATE" || "$BUILD_DATE" == "$PR_MERGE_DATE" ]]; then
    log_success "✅ Build date ($BUILD_DATE) is after PR #2978 target date"
else
    log_warning "⚠️  Build date ($BUILD_DATE) may not contain PR #2978"
fi

# 2. Check MNP CRD availability
log_info "=== 2. Multi-Network Policy Support Check ==="
if oc api-resources | grep -q "multi-networkpolicies"; then
    log_success "✅ MultiNetworkPolicy CRD is available"
    MNP_VERSION=$(oc api-resources | grep multi-networkpolicies | awk '{print $3}')
    echo "   API Version: $MNP_VERSION"
else
    log_error "❌ MultiNetworkPolicy CRD not found"
    exit 1
fi

# 3. Check for deployed MNPs
log_info "=== 3. Deployed Multi-Network Policies ==="
MNP_COUNT=$(oc get multi-networkpolicies.k8s.cni.cncf.io -A --no-headers 2>/dev/null | wc -l)
echo "Total MNPs deployed: $MNP_COUNT"

if [[ $MNP_COUNT -gt 0 ]]; then
    log_success "✅ MNPs are deployed and active"
    
    # Show first few MNPs with timing info
    echo "Sample MNPs:"
    oc get multi-networkpolicies.k8s.cni.cncf.io -A --no-headers | head -3 | while read namespace name age; do
        echo "  - $namespace/$name (age: $age)"
    done
    
    # Get first MNP details for analysis
    FIRST_MNP=$(oc get multi-networkpolicies.k8s.cni.cncf.io -A --no-headers | head -1)
    NAMESPACE=$(echo $FIRST_MNP | awk '{print $1}')
    NAME=$(echo $FIRST_MNP | awk '{print $2}')
    
    log_info "=== 4. MNP ipBlock Structure Analysis ==="
    echo "Analyzing MNP: $NAMESPACE/$NAME"
    
    # Count ipBlocks in the policy
    IPBLOCK_COUNT=$(oc get multi-networkpolicies.k8s.cni.cncf.io -n $NAMESPACE $NAME -o yaml | grep -c "ipBlock:" 2>/dev/null || echo "0")
    echo "Number of ipBlocks in policy: $IPBLOCK_COUNT"
    
    if [[ $IPBLOCK_COUNT -gt 1 ]]; then
        log_success "✅ Multiple ipBlocks found ($IPBLOCK_COUNT) - Perfect test case for PR #2978"
        echo "Sample ipBlocks (first 6):"
        oc get multi-networkpolicies.k8s.cni.cncf.io -n $NAMESPACE $NAME -o yaml | grep -A 1 "ipBlock:" | head -6
    else
        log_warning "⚠️  Only $IPBLOCK_COUNT ipBlock found"
    fi
    
    # Calculate expected impact
    TOTAL_IPBLOCKS=$((MNP_COUNT * IPBLOCK_COUNT))
    log_info "=== 5. Scale Analysis ==="
    echo "Total ipBlocks across all MNPs: $TOTAL_IPBLOCKS"
    echo "Without PR #2978: ~$TOTAL_IPBLOCKS separate ACLs expected"
    echo "With PR #2978: ~$MNP_COUNT consolidated ACLs expected"
    echo "Expected reduction: $(( (TOTAL_IPBLOCKS - MNP_COUNT) * 100 / TOTAL_IPBLOCKS ))% fewer ACLs"
    
else
    log_warning "⚠️  No MNPs available for analysis"
fi

# 6. Check ACL count and consolidation patterns
log_info "=== 6. OVN ACL Analysis ==="

# Find appropriate OVN pod
NODE_POD=$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node --no-headers | head -1 | awk '{print $1}' 2>/dev/null || echo "")
CONTROL_POD=$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-control-plane --no-headers | head -1 | awk '{print $1}' 2>/dev/null || echo "")

if [[ -n "$NODE_POD" ]]; then
    echo "Using ovnkube-node pod: $NODE_POD"
    POD_TO_USE="$NODE_POD"
    CONTAINER="nbdb"
elif [[ -n "$CONTROL_POD" ]]; then
    echo "Using ovnkube-control-plane pod: $CONTROL_POD" 
    POD_TO_USE="$CONTROL_POD"
    CONTAINER="ovnkube-cluster-manager"
else
    log_error "❌ Could not find appropriate OVN pod"
    return 1
fi

# Try to get ACL count with timeout and multiple attempts
log_info "Checking ACL count (timeout 30s, may take time with large datasets)..."
ACL_COUNT="timeout"

# Try multiple approaches to get ACL count
for attempt in 1 2 3; do
    log_info "ACL count attempt $attempt..."
    
    if [[ "$CONTAINER" == "nbdb" ]]; then
        ACL_COUNT=$(timeout 30 oc -n openshift-ovn-kubernetes exec $POD_TO_USE -c $CONTAINER -- ovn-nbctl --timeout=10 --no-headings --columns=_uuid list ACL 2>/dev/null | wc -l || echo "timeout")
    else
        # Try different approach for control plane pod
        ACL_COUNT=$(timeout 30 oc -n openshift-ovn-kubernetes exec $POD_TO_USE -c $CONTAINER -- sh -c 'echo "list ACL" | ovn-nbctl' 2>/dev/null | grep -c "^_uuid" || echo "timeout")
    fi
    
    if [[ "$ACL_COUNT" != "timeout" && "$ACL_COUNT" =~ ^[0-9]+$ ]]; then
        break
    else
        log_warning "Attempt $attempt failed, retrying..."
        sleep 5
    fi
done

if [[ "$ACL_COUNT" == "timeout" ]]; then
    log_warning "⚠️  ACL query timed out (system under heavy load)"
    log_info "   This could indicate ACL explosion without PR #2978 fix"
    ACL_STATUS="timeout_detected"
elif [[ "$ACL_COUNT" =~ ^[0-9]+$ ]]; then
    log_success "✅ ACL count retrieved: $ACL_COUNT"
    
    # Analyze ACL count relative to ipBlocks
    if [[ $MNP_COUNT -gt 0 && $IPBLOCK_COUNT -gt 0 ]]; then
        EXPECTED_WITHOUT_FIX=$((TOTAL_IPBLOCKS * 2))  # Rough estimate (ingress + egress)
        EXPECTED_WITH_FIX=$((MNP_COUNT * 4))          # Consolidated estimate
        
        echo "Analysis:"
        echo "  Expected ACLs without fix: ~$EXPECTED_WITHOUT_FIX"
        echo "  Expected ACLs with fix: ~$EXPECTED_WITH_FIX"
        echo "  Actual ACLs: $ACL_COUNT"
        
        if [[ $ACL_COUNT -lt $EXPECTED_WITH_FIX ]]; then
            log_success "✅ ACL count suggests PR #2978 ipBlock consolidation is WORKING!"
            ACL_STATUS="consolidation_working"
        elif [[ $ACL_COUNT -gt $EXPECTED_WITHOUT_FIX ]]; then
            log_warning "⚠️  ACL count suggests NO consolidation - PR #2978 may not be active"
            ACL_STATUS="no_consolidation"
        else
            log_info "ℹ️  ACL count in middle range - needs further analysis"
            ACL_STATUS="unclear"
        fi
    fi
    
    # Check for OR patterns (consolidation indicators)
    log_info "Checking for ACL consolidation patterns..."
    OR_PATTERNS=$(timeout 15 oc -n openshift-ovn-kubernetes exec $POD_TO_USE -c $CONTAINER -- ovn-nbctl --timeout=5 find ACL match~='||' 2>/dev/null | wc -l || echo "0")
    
    if [[ "$OR_PATTERNS" =~ ^[0-9]+$ ]] && [[ $OR_PATTERNS -gt 0 ]]; then
        log_success "✅ Found $OR_PATTERNS ACLs with OR patterns - Consolidation active!"
    else
        log_warning "⚠️  No OR patterns found - ipBlocks may not be consolidated"
    fi
else
    log_error "❌ Could not determine ACL count"
    ACL_STATUS="query_failed"
fi

# 7. System stability check
log_info "=== 7. System Stability Analysis ==="
WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker= --no-headers | wc -l)
echo "Worker nodes: $WORKER_COUNT"

# Check OVN pod health
OVN_PODS_READY=$(oc get pods -n openshift-ovn-kubernetes --no-headers | grep -c "Running" || echo "0")
OVN_PODS_TOTAL=$(oc get pods -n openshift-ovn-kubernetes --no-headers | wc -l)
echo "OVN pods: $OVN_PODS_READY/$OVN_PODS_TOTAL ready"

# Check for restarts
OVN_RESTARTS=$(oc get pods -n openshift-ovn-kubernetes -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' | awk '{sum+=$1} END {print sum+0}')
echo "Total OVN pod restarts: $OVN_RESTARTS"

if [[ $OVN_RESTARTS -gt 5 ]]; then
    log_warning "⚠️  High restart count ($OVN_RESTARTS) - possible system instability"
else
    log_success "✅ Low restart count - system appears stable"
fi

# 8. Generate verification summary
log_info "=== 8. Verification Summary ==="
echo
echo "PR #2978 Status Assessment:"

# Build validation
if [[ "$BUILD_DATE" > "$PR_MERGE_DATE" || "$BUILD_DATE" == "$PR_MERGE_DATE" ]]; then
    echo "✅ Build version: Contains expected timeframe"
else
    echo "❌ Build version: May not contain PR #2978"
fi

# Feature validation
if oc api-resources | grep -q "multi-networkpolicies"; then
    echo "✅ MNP support: Available"
else
    echo "❌ MNP support: Missing"
fi

# Test validation
if [[ $MNP_COUNT -gt 0 && $IPBLOCK_COUNT -gt 1 ]]; then
    echo "✅ Test case: Active with $MNP_COUNT MNPs, $IPBLOCK_COUNT ipBlocks each"
else
    echo "⚠️  Test case: Limited or inactive"
fi

# Consolidation validation
case $ACL_STATUS in
    "consolidation_working")
        echo "✅ ACL consolidation: WORKING - PR #2978 appears active!"
        ;;
    "no_consolidation")
        echo "❌ ACL consolidation: NOT working - PR #2978 may not be active"
        ;;
    "timeout_detected")
        echo "⚠️  ACL consolidation: System overloaded (possible ACL explosion)"
        ;;
    *)
        echo "⚠️  ACL consolidation: Status unclear"
        ;;
esac

# Stability validation
if [[ $OVN_RESTARTS -le 5 && $OVN_PODS_READY -eq $OVN_PODS_TOTAL ]]; then
    echo "✅ System stability: Good"
else
    echo "⚠️  System stability: Issues detected"
fi

echo
echo "=== Verification Complete ==="

# Export results for main script
export VERIFY_MNP_COUNT="$MNP_COUNT"
export VERIFY_IPBLOCK_COUNT="$IPBLOCK_COUNT"
export VERIFY_ACL_COUNT="$ACL_COUNT"
export VERIFY_ACL_STATUS="$ACL_STATUS"
export VERIFY_OR_PATTERNS="$OR_PATTERNS"
export VERIFY_TOTAL_IPBLOCKS="$TOTAL_IPBLOCKS"

VERIFY_EOF

chmod +x /tmp/verify-pr2978-fix.sh

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

# Run initial PR #2978 verification
log_info "🔍 Running initial PR #2978 fix verification..."
/tmp/verify-pr2978-fix.sh | tee "$ARTIFACT_DIR/pr2978_verification_initial.log"

# Store verification results for comparison
initial_verification_status="$VERIFY_ACL_STATUS"

# Baseline measurements
log_info "📏 Taking baseline measurements..."

# Function to get OVN database size
get_ovn_db_size() {
    local ovn_master_pod
    ovn_master_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "$ovn_master_pod" ]]; then
        oc exec -n openshift-ovn-kubernetes "$ovn_master_pod" -c ovnkube-master -- du -sh /etc/ovn/ 2>/dev/null | cut -f1 || echo "unknown"
    else
        echo "unknown"
    fi
}

# Function to count ACLs
count_acls() {
    local ovn_master_pod
    ovn_master_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    if [[ -n "$ovn_master_pod" ]]; then
        oc exec -n openshift-ovn-kubernetes "$ovn_master_pod" -c ovnkube-master -- ovn-nbctl list acl 2>/dev/null | grep -c "^_uuid" || echo "0"
    else
        echo "0"
    fi
}

# Function to monitor logical flow recomputation time
monitor_flow_recomputation() {
    local ovn_master_pod
    ovn_master_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
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

# Run post-test PR #2978 verification
log_info "🔍 Running post-test PR #2978 fix verification..."
/tmp/verify-pr2978-fix.sh | tee "$ARTIFACT_DIR/pr2978_verification_final.log"

# Store final verification results
final_verification_status="$VERIFY_ACL_STATUS"
final_verify_acl_count="$VERIFY_ACL_COUNT"
final_verify_or_patterns="$VERIFY_OR_PATTERNS"

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

# Save comprehensive test results with PR #2978 verification
cat > "$ARTIFACT_DIR/test_results.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "test_duration_seconds": $execution_duration,
    "reproduction_status": "completed",
    "pr2978_verification": {
        "initial_status": "$initial_verification_status",
        "final_status": "$final_verification_status",
        "final_acl_count": "$final_verify_acl_count",
        "or_patterns_detected": "$final_verify_or_patterns",
        "consolidation_working": $(if [[ "$final_verification_status" == "consolidation_working" ]]; then echo "true"; else echo "false"; fi)
    },
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

## PR #2978 Fix Verification Results
- **Initial Verification Status**: $initial_verification_status
- **Final Verification Status**: $final_verification_status
- **ACL Consolidation Working**: $(if [[ "$final_verification_status" == "consolidation_working" ]]; then echo "✅ YES - Fix is active!"; else echo "❌ NO - Fix not detected"; fi)
- **OR Patterns in ACLs**: $final_verify_or_patterns $(if [[ "$final_verify_or_patterns" =~ ^[0-9]+$ ]] && [[ $final_verify_or_patterns -gt 0 ]]; then echo "(✅ Consolidation patterns found)"; else echo "(⚠️  No consolidation detected)"; fi)

## Customer Issue Reproduction Status
$(if [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]]; then 
    echo "🎯 **CUSTOMER ISSUE SUCCESSFULLY REPRODUCED**"
    echo "- ACL count exceeded 1M threshold ($post_acl_count ACLs)"
    echo "- This matches the customer's MNP-76500 scenario"
    echo "- System likely experiencing performance degradation"
    if [[ "$final_verification_status" != "consolidation_working" ]]; then
        echo "- ⚠️  **PR #2978 fix NOT active** - ACL explosion without consolidation"
    fi
else
    echo "ℹ️  **Customer issue not fully reproduced**"
    echo "- ACL count below explosion threshold"
    if [[ "$final_verification_status" == "consolidation_working" ]]; then
        echo "- ✅ **PR #2978 fix appears to be working** - ACLs consolidated successfully"
    else
        echo "- May need larger scale or different parameters"
    fi
fi)

## Fix Effectiveness Analysis
$(if [[ "$final_verification_status" == "consolidation_working" ]]; then
    echo "✅ **PR #2978 CONSOLIDATION DETECTED**"
    echo "- Multiple ipBlocks are being consolidated into single ACLs"
    echo "- OR patterns found in ACL match conditions: $final_verify_or_patterns"
    echo "- System should handle large-scale MNP deployments efficiently"
elif [[ "$final_verification_status" == "no_consolidation" ]]; then
    echo "❌ **NO CONSOLIDATION DETECTED**"
    echo "- Each ipBlock appears to create separate ACLs"
    echo "- PR #2978 fix may not be active in this build"
    echo "- System vulnerable to ACL explosion with large MNP deployments"
else
    echo "⚠️  **CONSOLIDATION STATUS UNCLEAR**"
    echo "- Unable to definitively determine if PR #2978 is active"
    echo "- May require manual analysis of ACL patterns"
fi)

## Next Steps
1. **If consolidation working**: Monitor performance at larger scales, validate customer deployment
2. **If no consolidation**: Verify PR #2978 merge status, check build integration
3. Compare ACL patterns manually: \`ovn-nbctl list ACL | grep "match.*||"\`
4. Performance comparison before/after optimization

---
*Generated on $(date) by MNP-76500 reproduction test*
EOF

# Final status with PR #2978 verification
log_info "🏁 FINAL TEST RESULTS SUMMARY"
log_info "=============================="

# Customer issue reproduction status
if [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]]; then
    log_success "🎯 MNP-76500 CUSTOMER ISSUE SUCCESSFULLY REPRODUCED!"
    log_success "   ACL Explosion detected: $post_acl_count ACLs > $acl_explosion_threshold threshold"
    log_success "   This validates the customer's reported scenario"
else
    log_info "ℹ️  Test completed but customer ACL explosion not reproduced"
    log_info "   ACL count: $post_acl_count (threshold: $acl_explosion_threshold)"
fi

# PR #2978 verification status
log_info "🔍 PR #2978 VERIFICATION SUMMARY:"
case $final_verification_status in
    "consolidation_working")
        log_success "✅ PR #2978 FIX IS WORKING!"
        log_success "   - ipBlock consolidation detected"
        log_success "   - OR patterns in ACLs: $final_verify_or_patterns"
        log_success "   - System should handle MNP scale efficiently"
        ;;
    "no_consolidation")
        log_warning "❌ PR #2978 FIX NOT DETECTED"
        log_warning "   - No ipBlock consolidation found"
        log_warning "   - Each ipBlock creates separate ACLs"
        log_warning "   - System vulnerable to ACL explosion"
        ;;
    "timeout_detected")
        log_warning "⚠️  SYSTEM OVERLOADED - POSSIBLE ACL EXPLOSION"
        log_warning "   - ACL queries timing out"
        log_warning "   - May indicate fix is not active"
        ;;
    *)
        log_info "⚠️  PR #2978 STATUS UNCLEAR"
        log_info "   - Unable to determine consolidation status"
        log_info "   - Manual analysis may be required"
        ;;
esac

# Test outcome determination
if [[ "$final_verification_status" == "consolidation_working" ]]; then
    log_success "🎉 TEST OUTCOME: PR #2978 ipBlock consolidation is WORKING!"
    log_success "   The fix successfully prevents ACL explosion in large MNP deployments."
elif [[ "$post_acl_count" =~ ^[0-9]+$ ]] && [[ $post_acl_count -gt $acl_explosion_threshold ]] && [[ "$final_verification_status" == "no_consolidation" ]]; then
    log_warning "⚠️  TEST OUTCOME: Customer issue reproduced, but PR #2978 fix NOT active"
    log_warning "   This demonstrates the problem exists and the fix is needed."
else
    log_info "ℹ️  TEST OUTCOME: Partial results - further investigation needed"
fi

log_info "📁 Test artifacts saved to: $ARTIFACT_DIR"
log_info "📄 Summary report: $ARTIFACT_DIR/MNP-76500_test_summary.md"
log_info "📊 Detailed results: $ARTIFACT_DIR/test_results.json"
log_info "🔍 Initial verification: $ARTIFACT_DIR/pr2978_verification_initial.log" 
log_info "🔍 Final verification: $ARTIFACT_DIR/pr2978_verification_final.log"
log_info "📋 Main test log: $LOG_FILE"

echo "=========================================================="
echo "🏁 MNP-76500 ACL Test Completed"
echo "=========================================================="
