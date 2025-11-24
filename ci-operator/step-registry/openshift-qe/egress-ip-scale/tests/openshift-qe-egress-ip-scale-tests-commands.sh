#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Scale Test - SNAT/LRP Validation and Failover Testing
# Tests 10 EgressIPs with 200 pods each (2000 total pods)

echo "Starting OpenShift QE Egress IP Scale Test"
echo "=========================================="

# Configuration
EIP_COUNT="${EIP_COUNT:-10}"
PODS_PER_EIP="${PODS_PER_EIP:-200}"
TOTAL_PODS=$((EIP_COUNT * PODS_PER_EIP))
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-scale-eip}"
NAMESPACE="openshift-ovn-kubernetes"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Logging setup
LOG_FILE="$ARTIFACT_DIR/scale_test_$(date +%Y%m%d_%H%M%S).log"
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

log_info "Scale Test Configuration:"
log_info "  - EgressIP objects: $EIP_COUNT"
log_info "  - Pods per EgressIP: $PODS_PER_EIP" 
log_info "  - Total pods: $TOTAL_PODS"
log_info "  - Expected SNAT rules: $TOTAL_PODS"
log_info "  - Expected LRP rules: $TOTAL_PODS"

# Function to count SNAT rules for all EgressIPs
count_snat_rules() {
    local total_snat=0
    local ovn_master_pod
    
    ovn_master_pod=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    
    if [[ -z "$ovn_master_pod" ]]; then
        log_error "No ovnkube-master pod found"
        echo "0"
        return 1
    fi
    
    # Count SNAT rules for each EgressIP
    for ((i=1; i<=EIP_COUNT; i++)); do
        local eip_name="eip-scale-$i"
        local egress_ip
        egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
        
        if [[ -n "$egress_ip" ]]; then
            local snat_count
            snat_count=$(oc exec -n "$NAMESPACE" "$ovn_master_pod" -c northd -- \
                ovn-sbctl --timeout=30 find NAT external_ip="$egress_ip" 2>/dev/null | grep -c "external_ip" || echo "0")
            total_snat=$((total_snat + snat_count))
            log_info "EgressIP $eip_name ($egress_ip): $snat_count SNAT rules"
        fi
    done
    
    echo "$total_snat"
}

# Function to count LRP (Logical Router Policy) rules for all EgressIPs  
count_lrp_rules() {
    local total_lrp=0
    local ovn_master_pod
    
    ovn_master_pod=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    
    if [[ -z "$ovn_master_pod" ]]; then
        log_error "No ovnkube-master pod found"
        echo "0"
        return 1
    fi
    
    # Count LRP rules for each EgressIP
    for ((i=1; i<=EIP_COUNT; i++)); do
        local eip_name="eip-scale-$i"
        local egress_ip
        egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
        
        if [[ -n "$egress_ip" ]]; then
            local lrp_count
            lrp_count=$(oc exec -n "$NAMESPACE" "$ovn_master_pod" -c northd -- \
                ovn-nbctl --timeout=30 find Logical_Router_Policy nexthop="$egress_ip" 2>/dev/null | grep -c "nexthop" || echo "0")
            total_lrp=$((total_lrp + lrp_count))
            log_info "EgressIP $eip_name ($egress_ip): $lrp_count LRP rules"
        fi
    done
    
    echo "$total_lrp"
}

# Function to get SNAT rules count for a specific node
count_snat_rules_by_node() {
    local target_node="$1"
    local total_snat=0
    local ovn_master_pod
    
    ovn_master_pod=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-master --no-headers -o custom-columns=":metadata.name" | head -1)
    
    # Get all EgressIPs assigned to the target node
    for ((i=1; i<=EIP_COUNT; i++)); do
        local eip_name="eip-scale-$i"
        local assigned_node
        assigned_node=$(oc get egressip "$eip_name" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        
        if [[ "$assigned_node" == "$target_node" ]]; then
            local egress_ip
            egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
            
            if [[ -n "$egress_ip" ]]; then
                local snat_count
                snat_count=$(oc exec -n "$NAMESPACE" "$ovn_master_pod" -c northd -- \
                    ovn-sbctl --timeout=30 find NAT external_ip="$egress_ip" 2>/dev/null | grep -c "external_ip" || echo "0")
                total_snat=$((total_snat + snat_count))
            fi
        fi
    done
    
    echo "$total_snat"
}

# Function to collect detailed scale metrics
collect_scale_metrics() {
    local phase="$1"
    local metrics_file="$ARTIFACT_DIR/scale_metrics_${phase}_$(date +%Y%m%d_%H%M%S).json"
    
    log_info "Collecting scale test metrics for phase: $phase"
    
    local total_snat total_lrp
    total_snat=$(count_snat_rules)
    total_lrp=$(count_lrp_rules)
    
    cat > "$metrics_file" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phase": "$phase",
  "configuration": {
    "eip_count": $EIP_COUNT,
    "pods_per_eip": $PODS_PER_EIP,
    "total_pods": $TOTAL_PODS,
    "expected_snat_rules": $TOTAL_PODS,
    "expected_lrp_rules": $TOTAL_PODS
  },
  "measurements": {
    "total_snat_rules": $total_snat,
    "total_lrp_rules": $total_lrp,
    "snat_compliance": $(if [[ $total_snat -eq $TOTAL_PODS ]]; then echo "true"; else echo "false"; fi),
    "lrp_compliance": $(if [[ $total_lrp -eq $TOTAL_PODS ]]; then echo "true"; else echo "false"; fi)
  },
  "egressip_details": [
EOF

    # Collect per-EgressIP details
    for ((i=1; i<=EIP_COUNT; i++)); do
        local eip_name="eip-scale-$i"
        local egress_ip assigned_node
        egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "unknown")
        assigned_node=$(oc get egressip "$eip_name" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "unassigned")
        
        # Count pods in corresponding namespace
        local namespace="${NAMESPACE_PREFIX}$i"
        local ready_pods
        ready_pods=$(oc get pods -n "$namespace" -l app=scale-test-pod --field-selector=status.phase=Running --no-headers | wc -l)
        
        cat >> "$metrics_file" << EOF
    {
      "eip_name": "$eip_name",
      "egress_ip": "$egress_ip", 
      "assigned_node": "$assigned_node",
      "namespace": "$namespace",
      "ready_pods": $ready_pods,
      "expected_pods": $PODS_PER_EIP
    }$(if [[ $i -lt $EIP_COUNT ]]; then echo ","; fi)
EOF
    done
    
    cat >> "$metrics_file" << EOF
  ]
}
EOF

    log_info "Scale metrics saved to: $metrics_file"
}

# Validate prerequisites
log_info "Validating scale test prerequisites..."

# Check if EgressIPs exist
EXISTING_EIPS=$(oc get egressip -o name | grep "eip-scale-" | wc -l)
if [[ $EXISTING_EIPS -lt $EIP_COUNT ]]; then
    error_exit "Expected $EIP_COUNT EgressIPs, found only $EXISTING_EIPS. Run setup first."
fi

# Check if namespaces exist  
EXISTING_NAMESPACES=0
for ((i=1; i<=EIP_COUNT; i++)); do
    if oc get namespace "${NAMESPACE_PREFIX}$i" &>/dev/null; then
        EXISTING_NAMESPACES=$((EXISTING_NAMESPACES + 1))
    fi
done

if [[ $EXISTING_NAMESPACES -lt $EIP_COUNT ]]; then
    error_exit "Expected $EIP_COUNT namespaces, found only $EXISTING_NAMESPACES. Run setup first."
fi

log_success "Prerequisites validated. Found $EXISTING_EIPS EgressIPs and $EXISTING_NAMESPACES namespaces."

# Phase 1: Baseline SNAT/LRP Rule Validation
log_info "==============================="
log_info "PHASE 1: Baseline SNAT/LRP Rule Validation"
log_info "==============================="

collect_scale_metrics "baseline"

log_info "Validating SNAT and LRP rule counts..."

TOTAL_SNAT_RULES=$(count_snat_rules)
TOTAL_LRP_RULES=$(count_lrp_rules)

log_info "Rule Count Results:"
log_info "  - Total SNAT rules: $TOTAL_SNAT_RULES (expected: $TOTAL_PODS)"
log_info "  - Total LRP rules: $TOTAL_LRP_RULES (expected: $TOTAL_PODS)"

# Validate rule counts
if [[ $TOTAL_SNAT_RULES -eq $TOTAL_PODS ]]; then
    log_success "✅ SNAT rule count matches expected value"
    echo "baseline,snat,$TOTAL_SNAT_RULES,$TOTAL_PODS,pass" >> "$ARTIFACT_DIR/rule_validation.csv"
else
    log_error "❌ SNAT rule count mismatch: $TOTAL_SNAT_RULES vs $TOTAL_PODS expected"
    echo "baseline,snat,$TOTAL_SNAT_RULES,$TOTAL_PODS,fail" >> "$ARTIFACT_DIR/rule_validation.csv"
fi

if [[ $TOTAL_LRP_RULES -eq $TOTAL_PODS ]]; then
    log_success "✅ LRP rule count matches expected value"
    echo "baseline,lrp,$TOTAL_LRP_RULES,$TOTAL_PODS,pass" >> "$ARTIFACT_DIR/rule_validation.csv"
else
    log_error "❌ LRP rule count mismatch: $TOTAL_LRP_RULES vs $TOTAL_PODS expected"
    echo "baseline,lrp,$TOTAL_LRP_RULES,$TOTAL_PODS,fail" >> "$ARTIFACT_DIR/rule_validation.csv"
fi

# Phase 2: EgressIP Failover Testing
log_info "==============================="
log_info "PHASE 2: EgressIP Failover Testing"
log_info "==============================="

# Select an EgressIP for failover testing
FAILOVER_EIP="eip-scale-1"
ORIGINAL_NODE=$(oc get egressip "$FAILOVER_EIP" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")

if [[ -z "$ORIGINAL_NODE" ]]; then
    log_error "Cannot determine assigned node for $FAILOVER_EIP"
    exit 1
fi

log_info "Testing failover for $FAILOVER_EIP currently assigned to: $ORIGINAL_NODE"

# Count SNAT rules on original node before failover
ORIGINAL_NODE_SNAT_BEFORE=$(count_snat_rules_by_node "$ORIGINAL_NODE")
log_info "SNAT rules on original node $ORIGINAL_NODE before failover: $ORIGINAL_NODE_SNAT_BEFORE"

# Get other available nodes
AVAILABLE_NODES=$(oc get nodes -l k8s.ovn.org/egress-assignable= --no-headers -o custom-columns=":metadata.name" | grep -v "$ORIGINAL_NODE")

if [[ -z "$AVAILABLE_NODES" ]]; then
    log_warning "No other egress-assignable nodes available for failover testing"
    log_info "Skipping failover test"
else
    TARGET_NODE=$(echo "$AVAILABLE_NODES" | head -1)
    log_info "Target node for failover: $TARGET_NODE"
    
    # Remove egress-assignable label from original node to trigger failover
    log_info "Removing egress-assignable label from $ORIGINAL_NODE to trigger failover..."
    oc label node "$ORIGINAL_NODE" k8s.ovn.org/egress-assignable- 2>/dev/null || true
    
    # Wait for failover to complete
    log_info "Waiting for EgressIP failover..."
    FAILOVER_TIMEOUT=300
    ELAPSED=0
    FAILOVER_SUCCESSFUL=false
    
    while [[ $ELAPSED -lt $FAILOVER_TIMEOUT ]]; do
        NEW_ASSIGNED_NODE=$(oc get egressip "$FAILOVER_EIP" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        
        if [[ -n "$NEW_ASSIGNED_NODE" && "$NEW_ASSIGNED_NODE" != "$ORIGINAL_NODE" ]]; then
            log_success "✅ Failover successful! $FAILOVER_EIP now assigned to: $NEW_ASSIGNED_NODE"
            FAILOVER_SUCCESSFUL=true
            break
        fi
        
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        
        if [[ $((ELAPSED % 60)) -eq 0 ]]; then
            log_info "Failover in progress... elapsed: ${ELAPSED}s"
        fi
    done
    
    if [[ "$FAILOVER_SUCCESSFUL" == "true" ]]; then
        # Wait for SNAT rules to stabilize
        log_info "Waiting for SNAT rules to stabilize after failover..."
        sleep 30
        
        # Validate SNAT rules on original node should be 0
        ORIGINAL_NODE_SNAT_AFTER=$(count_snat_rules_by_node "$ORIGINAL_NODE")
        log_info "SNAT rules on original node $ORIGINAL_NODE after failover: $ORIGINAL_NODE_SNAT_AFTER"
        
        if [[ $ORIGINAL_NODE_SNAT_AFTER -eq 0 ]]; then
            log_success "✅ Original node SNAT rules correctly dropped to 0 after failover"
            echo "failover,original_node_snat_after,$ORIGINAL_NODE_SNAT_AFTER,0,pass" >> "$ARTIFACT_DIR/rule_validation.csv"
        else
            log_error "❌ Original node still has $ORIGINAL_NODE_SNAT_AFTER SNAT rules after failover"
            echo "failover,original_node_snat_after,$ORIGINAL_NODE_SNAT_AFTER,0,fail" >> "$ARTIFACT_DIR/rule_validation.csv"
        fi
        
        # Verify total SNAT/LRP rules remain consistent
        collect_scale_metrics "post_failover"
        
        TOTAL_SNAT_AFTER=$(count_snat_rules)
        TOTAL_LRP_AFTER=$(count_lrp_rules)
        
        log_info "Rule counts after failover:"
        log_info "  - Total SNAT rules: $TOTAL_SNAT_AFTER (expected: $TOTAL_PODS)"
        log_info "  - Total LRP rules: $TOTAL_LRP_AFTER (expected: $TOTAL_PODS)"
        
        if [[ $TOTAL_SNAT_AFTER -eq $TOTAL_PODS ]]; then
            log_success "✅ Total SNAT rules maintained after failover"
            echo "post_failover,total_snat,$TOTAL_SNAT_AFTER,$TOTAL_PODS,pass" >> "$ARTIFACT_DIR/rule_validation.csv"
        else
            log_error "❌ Total SNAT rules inconsistent after failover: $TOTAL_SNAT_AFTER vs $TOTAL_PODS"
            echo "post_failover,total_snat,$TOTAL_SNAT_AFTER,$TOTAL_PODS,fail" >> "$ARTIFACT_DIR/rule_validation.csv"
        fi
        
        # Restore egress-assignable label
        log_info "Restoring egress-assignable label to $ORIGINAL_NODE..."
        oc label node "$ORIGINAL_NODE" k8s.ovn.org/egress-assignable="" --overwrite || true
        
    else
        log_error "❌ Failover did not complete within ${FAILOVER_TIMEOUT}s"
        echo "failover,completion,timeout,$FAILOVER_TIMEOUT,fail" >> "$ARTIFACT_DIR/rule_validation.csv"
        
        # Restore label anyway
        oc label node "$ORIGINAL_NODE" k8s.ovn.org/egress-assignable="" --overwrite || true
    fi
fi

# Phase 3: Final Validation
log_info "==============================="
log_info "PHASE 3: Final Validation"
log_info "==============================="

collect_scale_metrics "final"

# Generate test summary
TOTAL_TESTS=$(wc -l < "$ARTIFACT_DIR/rule_validation.csv" 2>/dev/null || echo "0")
PASSED_TESTS=$(grep -c ",pass$" "$ARTIFACT_DIR/rule_validation.csv" 2>/dev/null || echo "0")
FAILED_TESTS=$(grep -c ",fail$" "$ARTIFACT_DIR/rule_validation.csv" 2>/dev/null || echo "0")

log_info "==============================="
log_info "SCALE TEST SUMMARY"
log_info "==============================="
log_info "Configuration:"
log_info "  - EgressIP objects: $EIP_COUNT"
log_info "  - Pods per EgressIP: $PODS_PER_EIP"
log_info "  - Total pods: $TOTAL_PODS"
log_info ""
log_info "Test Results:"
log_info "  - Total validations: $TOTAL_TESTS"
log_info "  - Passed: $PASSED_TESTS"
log_info "  - Failed: $FAILED_TESTS"
log_info "  - Success rate: $((PASSED_TESTS * 100 / TOTAL_TESTS))%" 2>/dev/null || log_info "  - Success rate: 0%"
log_info ""
log_info "Final Rule Counts:"
FINAL_SNAT=$(count_snat_rules)
FINAL_LRP=$(count_lrp_rules)
log_info "  - SNAT rules: $FINAL_SNAT/$TOTAL_PODS"
log_info "  - LRP rules: $FINAL_LRP/$TOTAL_PODS"

# Create comprehensive summary file
cat > "$ARTIFACT_DIR/scale_test_summary.txt" << EOF
OpenShift QE Egress IP Scale Test Summary
==========================================

Configuration:
- EgressIP objects: $EIP_COUNT
- Pods per EgressIP: $PODS_PER_EIP
- Total pods: $TOTAL_PODS
- Expected SNAT rules: $TOTAL_PODS
- Expected LRP rules: $TOTAL_PODS

Test Results:
- Total validations: $TOTAL_TESTS
- Passed: $PASSED_TESTS  
- Failed: $FAILED_TESTS
- Success rate: $((PASSED_TESTS * 100 / TOTAL_TESTS))%

Final Measurements:
- SNAT rules: $FINAL_SNAT/$TOTAL_PODS
- LRP rules: $FINAL_LRP/$TOTAL_PODS

Test completed at: $(date)
Total runtime: $SECONDS seconds
EOF

if [[ $FAILED_TESTS -eq 0 ]]; then
    log_success "🎉 Scale test completed successfully with all validations passed!"
else
    log_warning "⚠️ Scale test completed with $FAILED_TESTS failed validations"
    log_info "Check detailed results in: $ARTIFACT_DIR/rule_validation.csv"
fi

log_info "Comprehensive results saved to: $ARTIFACT_DIR/"