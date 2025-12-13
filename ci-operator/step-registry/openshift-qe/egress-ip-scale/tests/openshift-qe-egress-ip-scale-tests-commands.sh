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

# Function to discover OVN master pod and container
discover_ovn_master() {
    local ovn_master_pod ovn_container
    
    log_info "Searching for OVN master pods in namespace: $NAMESPACE"
    oc get pods -n "$NAMESPACE" -o wide | head -10 || log_error "Failed to list pods in $NAMESPACE"
    
    ovn_master_pod=$(oc get pods -n "$NAMESPACE" -o wide | grep "ovnkube-master" | awk '{print $1}' | head -1)
    
    if [[ -z "$ovn_master_pod" ]]; then
        log_error "No ovnkube-master pod found in namespace $NAMESPACE"
        log_info "Available pods in $NAMESPACE:"
        oc get pods -n "$NAMESPACE" | grep -E "(ovnkube|ovn)" || echo "No OVN pods found"
        return 1
    fi
    
    log_info "Using OVN master pod: $ovn_master_pod"
    
    # Discover containers in OVN master pod
    log_info "Discovering containers in OVN master pod..."
    oc get pod -n "$NAMESPACE" "$ovn_master_pod" -o jsonpath='{.spec.containers[*].name}' || log_error "Failed to get container names"
    
    # Try different container names for ovn-sbctl access
    for container in "northd" "ovnkube-master" "ovn-northd" "sbdb" "nbdb"; do
        if oc exec -n "$NAMESPACE" "$ovn_master_pod" -c "$container" -- echo "test" &>/dev/null; then
            log_info "Found accessible container: $container"
            ovn_container="$container"
            break
        fi
    done
    
    if [[ -z "$ovn_container" ]]; then
        log_error "Cannot find accessible container in OVN master pod $ovn_master_pod"
        return 1
    fi
    
    log_info "Using container: $ovn_container"
    echo "$ovn_master_pod:$ovn_container"
}

# Function to count SNAT rules for all EgressIPs
count_snat_rules() {
    local total_snat=0
    local ovn_info ovn_master_pod ovn_container
    
    # Discover OVN master pod and container
    if ! ovn_info=$(discover_ovn_master); then
        echo "0"
        return 1
    fi
    
    ovn_master_pod="${ovn_info%:*}"
    ovn_container="${ovn_info#*:}"
    
    # Count SNAT rules for each EgressIP
    for ((i=1; i<=EIP_COUNT; i++)); do
        local eip_name="eip-scale-$i"
        local egress_ip
        egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
        
        if [[ -n "$egress_ip" ]]; then
            log_info "Checking SNAT rules for $eip_name with IP $egress_ip"
            
            # First verify pod exists and is ready
            local pod_status
            pod_status=$(oc get pod -n "$NAMESPACE" "$ovn_master_pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            if [[ "$pod_status" != "Running" ]]; then
                log_error "OVN master pod $ovn_master_pod is not running (status: $pod_status)"
                echo "0"
                return 1
            fi
            
            # Try to execute the SNAT count command with error handling
            local snat_count
            log_info "Executing SNAT rule query for $egress_ip..."
            if ! snat_count=$(oc exec -n "$NAMESPACE" "$ovn_master_pod" -c "$ovn_container" -- \
                ovn-sbctl --timeout=30 find NAT external_ip="$egress_ip" 2>&1 | grep -c "external_ip" || echo "0"); then
                log_error "Failed to execute SNAT rule query for $eip_name"
                log_error "Command output: $snat_count"
                echo "0"
                return 1
            fi
            
            total_snat=$((total_snat + snat_count))
            log_info "EgressIP $eip_name ($egress_ip): $snat_count SNAT rules"
        else
            log_warning "EgressIP $eip_name has no assigned IP address"
        fi
    done
    
    echo "$total_snat"
}

# Function to count LRP (Logical Router Policy) rules for all EgressIPs  
count_lrp_rules() {
    local total_lrp=0
    local ovn_info ovn_master_pod ovn_container
    
    # Discover OVN master pod and container
    if ! ovn_info=$(discover_ovn_master); then
        echo "0"
        return 1
    fi
    
    ovn_master_pod="${ovn_info%:*}"
    ovn_container="${ovn_info#*:}"
    
    # Count LRP rules for each EgressIP
    for ((i=1; i<=EIP_COUNT; i++)); do
        local eip_name="eip-scale-$i"
        local egress_ip
        egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
        
        if [[ -n "$egress_ip" ]]; then
            local lrp_count
            lrp_count=$(oc exec -n "$NAMESPACE" "$ovn_master_pod" -c "$ovn_container" -- \
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
    local ovn_info ovn_master_pod ovn_container
    
    # Discover OVN master pod and container
    if ! ovn_info=$(discover_ovn_master); then
        echo "0"
        return 1
    fi
    
    ovn_master_pod="${ovn_info%:*}"
    ovn_container="${ovn_info#*:}"
    
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
                snat_count=$(oc exec -n "$NAMESPACE" "$ovn_master_pod" -c "$ovn_container" -- \
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
    local metrics_file
    metrics_file="$ARTIFACT_DIR/scale_metrics_${phase}_$(date +%Y%m%d_%H%M%S).json"
    
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
        local namespace
        namespace="${NAMESPACE_PREFIX}$i"
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

# Initialize validation results CSV
echo "phase,metric,actual,expected,result" > "$ARTIFACT_DIR/rule_validation.csv"

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

# Phase 2.5: Real Traffic Validation (Addresses @huiran0826 feedback)
log_info "==============================="
log_info "PHASE 2.5: Real Egress IP Traffic Validation"
log_info "==============================="

log_info "Testing actual traffic flow through egress IPs to external services..."
log_info "This validates real traffic usage instead of just SNAT/LRP rule checking"

# Function to test actual egress traffic
test_egress_traffic() {
    local eip_name="$1"
    local expected_eip="$2"
    local namespace
    namespace="${NAMESPACE_PREFIX}$(echo "$eip_name" | grep -o '[0-9]*$')"
    
    log_info "Testing traffic for $eip_name with IP $expected_eip in namespace $namespace"
    
    # Get a test pod from this namespace
    local test_pod
    test_pod=$(oc get pods -n "$namespace" -l app=scale-test-pod --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$test_pod" ]]; then
        log_warning "No running pods found in namespace $namespace for traffic testing"
        return 1
    fi
    
    log_info "Using test pod: $test_pod in namespace $namespace"
    
    # Test external connectivity and verify source IP
    local actual_source_ip
    if command -v "jq" >/dev/null 2>&1; then
        actual_source_ip=$(oc exec -n "$namespace" "$test_pod" -- timeout 30 curl -s https://httpbin.org/ip 2>/dev/null | jq -r '.origin' 2>/dev/null | cut -d',' -f1 | tr -d ' ' || echo "")
    else
        # Parse JSON response without jq
        local response
        response=$(oc exec -n "$namespace" "$test_pod" -- timeout 30 curl -s https://httpbin.org/ip 2>/dev/null || echo "")
        actual_source_ip=$(echo "$response" | sed -n 's/.*"origin":\s*"\([^"]*\)".*/\1/p' | cut -d',' -f1 | tr -d ' ')
    fi
    
    if [[ -n "$actual_source_ip" ]]; then
        if [[ "$actual_source_ip" == "$expected_eip" ]]; then
            log_success "✅ REAL TRAFFIC TEST PASSED for $eip_name"
            log_success "    External service sees correct egress IP: $actual_source_ip"
            echo "$eip_name,traffic_test,PASS,$actual_source_ip" >> "$ARTIFACT_DIR/traffic_validation.csv"
            return 0
        else
            log_error "❌ REAL TRAFFIC TEST FAILED for $eip_name"
            log_error "    Expected: $expected_eip, Actual: $actual_source_ip"
            
            # Try backup service
            log_info "Trying backup external service (ifconfig.me)..."
            local backup_ip
            backup_ip=$(oc exec -n "$namespace" "$test_pod" -- timeout 20 curl -s https://ifconfig.me 2>/dev/null | tr -d '\r\n ' || echo "")
            
            if [[ "$backup_ip" == "$expected_eip" ]]; then
                log_success "✅ BACKUP TRAFFIC TEST PASSED for $eip_name: $backup_ip"
                echo "$eip_name,traffic_test,PASS,$backup_ip" >> "$ARTIFACT_DIR/traffic_validation.csv"
                return 0
            else
                log_error "❌ BACKUP TRAFFIC TEST ALSO FAILED: expected $expected_eip, got '$backup_ip'"
                echo "$eip_name,traffic_test,FAIL,$actual_source_ip" >> "$ARTIFACT_DIR/traffic_validation.csv"
                return 1
            fi
        fi
    else
        log_error "❌ Could not reach external services from pod $test_pod"
        echo "$eip_name,traffic_test,FAIL,no_connectivity" >> "$ARTIFACT_DIR/traffic_validation.csv"
        return 1
    fi
}

# Initialize traffic validation results
echo "egressip,test_type,result,source_ip" > "$ARTIFACT_DIR/traffic_validation.csv"

# Test traffic for each EgressIP
traffic_tests_passed=0
traffic_tests_failed=0

for ((i=1; i<=EIP_COUNT; i++)); do
    eip_name="eip-scale-$i"
    egress_ip=$(oc get egressip "$eip_name" -o jsonpath='{.spec.egressIPs[0]}' 2>/dev/null || echo "")
    
    if [[ -n "$egress_ip" ]]; then
        if test_egress_traffic "$eip_name" "$egress_ip"; then
            traffic_tests_passed=$((traffic_tests_passed + 1))
        else
            traffic_tests_failed=$((traffic_tests_failed + 1))
        fi
        sleep 2  # Brief pause between tests
    else
        log_warning "Skipping traffic test for $eip_name - no IP defined"
        traffic_tests_failed=$((traffic_tests_failed + 1))
    fi
done

log_info "Real Traffic Validation Results:"
log_info "  - Tests Passed: $traffic_tests_passed"
log_info "  - Tests Failed: $traffic_tests_failed"
log_info "  - Success Rate: $((traffic_tests_passed * 100 / (traffic_tests_passed + traffic_tests_failed)))%"

if [[ $traffic_tests_passed -eq 0 ]]; then
    log_error "❌ ALL TRAFFIC TESTS FAILED - This indicates egress IPs are not working for actual traffic"
elif [[ $traffic_tests_failed -gt 0 ]]; then
    log_warning "⚠️  Some traffic tests failed - partial egress IP functionality"
else
    log_success "✅ ALL TRAFFIC TESTS PASSED - Egress IPs are working correctly for real traffic"
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
log_info "Real Traffic Validation Results:"
log_info "  - Traffic tests passed: $traffic_tests_passed"
log_info "  - Traffic tests failed: $traffic_tests_failed"
log_info "  - Traffic success rate: $((traffic_tests_passed * 100 / (traffic_tests_passed + traffic_tests_failed)))%"
log_info ""
log_info "Final Rule Counts (Reference):"
FINAL_SNAT=$(count_snat_rules)
FINAL_LRP=$(count_lrp_rules)
log_info "  - SNAT rules: $FINAL_SNAT/$TOTAL_PODS"
log_info "  - LRP rules: $FINAL_LRP/$TOTAL_PODS"
log_info ""
log_info "NOTE: Primary validation is real traffic flow, SNAT/LRP counts are reference only"

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

if [[ $FAILED_TESTS -eq 0 ]] && [[ $traffic_tests_failed -eq 0 ]]; then
    log_success "🎉 Scale test completed successfully with all validations passed!"
    log_success "✅ Both SNAT/LRP rule validation AND real traffic validation passed"
elif [[ $traffic_tests_passed -gt 0 ]]; then
    log_warning "⚠️ Scale test completed with some issues:"
    log_warning "  - SNAT/LRP validation failures: $FAILED_TESTS"
    log_warning "  - Traffic validation failures: $traffic_tests_failed"
    log_warning "  - Traffic validation successes: $traffic_tests_passed"
    log_info "Check detailed results in: $ARTIFACT_DIR/rule_validation.csv and $ARTIFACT_DIR/traffic_validation.csv"
else
    log_error "❌ Scale test failed - no successful traffic validations"
    log_error "This indicates egress IPs are not working for actual traffic flow"
    log_info "Check detailed results in: $ARTIFACT_DIR/rule_validation.csv and $ARTIFACT_DIR/traffic_validation.csv"
fi

log_info "Comprehensive results saved to: $ARTIFACT_DIR/"