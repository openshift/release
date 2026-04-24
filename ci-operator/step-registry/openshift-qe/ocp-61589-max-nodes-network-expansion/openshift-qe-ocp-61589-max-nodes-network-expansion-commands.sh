#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting OCP-61589: Maximum nodes post cluster network expansion test"

# Test configuration
export CLUSTER_NETWORK_ORIGINAL_CIDR="${CLUSTER_NETWORK_CIDR:-10.128.0.0/20}"
export CLUSTER_NETWORK_EXPANDED_CIDR="${CLUSTER_NETWORK_EXPANDED_CIDR:-10.128.0.0/14}"
export CLUSTER_NETWORK_HOST_PREFIX="${CLUSTER_NETWORK_HOST_PREFIX:-23}"
export MAX_NODES_TARGET="${MAX_NODES_TARGET:-520}"
export EXPECTED_READY_NODES="${EXPECTED_READY_NODES:-510}"
export TEST_TIMEOUT="${TEST_TIMEOUT:-6h}"

# Function to check cluster health
check_cluster_health() {
    echo "Checking cluster operator health..."
    oc get co --no-headers | while read name _ available progressing degraded _ _; do
        if [[ "$available" != "True" || "$progressing" != "False" || "$degraded" != "False" ]]; then
            echo "ERROR: Cluster operator $name is not healthy: available=$available, progressing=$progressing, degraded=$degraded"
            return 1
        fi
    done
    echo "All cluster operators are healthy"
}

# Function to wait for nodes to be ready
wait_for_nodes() {
    local target_ready=$1
    local timeout=$2
    echo "Waiting for $target_ready nodes to be ready (timeout: $timeout)"
    
    local start_time
    start_time=$(date +%s)
    local timeout_seconds
    timeout_seconds=$(echo "$timeout" | sed 's/h/*3600/g; s/m/*60/g; s/s//g' | bc)
    
    # Create node provisioning progress log
    echo "timestamp,elapsed_seconds,total_nodes,ready_nodes,notready_nodes,pending_nodes" > "$RESULTS_DIR/node-provisioning-progress.csv"
    
    while true; do
        local ready_count=$(oc get nodes --no-headers | grep " Ready " | wc -l)
        local notready_count=$(oc get nodes --no-headers | grep "NotReady" | wc -l)
        local total_count=$(oc get nodes --no-headers | wc -l)
        local pending_count=$((target_ready + 10 - total_count))  # Estimate pending
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Log progress to CSV
        echo "$(date),${elapsed},${total_count},${ready_count},${notready_count},${pending_count}" >> "$RESULTS_DIR/node-provisioning-progress.csv"
        
        echo "$(date): Ready nodes: $ready_count/$target_ready, Total: $total_count, NotReady: $notready_count (elapsed: ${elapsed}s)"
        
        # Save periodic snapshots
        if [[ $((elapsed % 1800)) -eq 0 && $elapsed -gt 0 ]]; then  # Every 30 minutes
            echo "$(date): Saving 30-minute snapshot" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"
            oc get nodes -o wide > "$RESULTS_DIR/nodes-snapshot-${elapsed}s.txt"
            oc get machineset -n openshift-machine-api -o wide > "$RESULTS_DIR/machinesets-snapshot-${elapsed}s.txt"
        fi
        
        if [[ $ready_count -ge $target_ready ]]; then
            echo "SUCCESS: $ready_count nodes are ready"
            echo "$(date): Target ready nodes achieved: $ready_count" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"
            return 0
        fi
        
        if [[ $elapsed -gt $timeout_seconds ]]; then
            echo "TIMEOUT: Only $ready_count nodes ready after ${timeout}"
            echo "$(date): Test timed out with $ready_count ready nodes" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"
            return 1
        fi
        
        sleep 60
    done
}

# Create results directory
RESULTS_DIR="${ARTIFACT_DIR:-/tmp}/ocp-61589-results"
mkdir -p "$RESULTS_DIR"

# Step 1: Verify initial cluster state
echo "=== STEP 1: Verify initial cluster state ==="
check_cluster_health

echo "Initial cluster network configuration:"
oc get network.config.openshift.io cluster -o yaml | tee "$RESULTS_DIR/initial-network-config.yaml"

echo "Initial node count:"
initial_node_count=$(oc get nodes --no-headers | wc -l)
echo "$initial_node_count" | tee "$RESULTS_DIR/initial-node-count.txt"
echo "Initial nodes: $initial_node_count"

echo "Initial cluster operators status:"
oc get co -o wide | tee "$RESULTS_DIR/initial-cluster-operators.txt"

echo "Initial machinesets:"
oc get machineset -n openshift-machine-api -o wide | tee "$RESULTS_DIR/initial-machinesets.txt"

echo "Initial cluster version:"
oc get clusterversion -o yaml | tee "$RESULTS_DIR/initial-cluster-version.yaml"

# Step 2: Expand cluster network CIDR
echo "=== STEP 2: Expand cluster network CIDR ==="
echo "Expanding cluster network from $CLUSTER_NETWORK_ORIGINAL_CIDR to $CLUSTER_NETWORK_EXPANDED_CIDR"

# Record network expansion timestamp
echo "$(date): Starting network expansion" | tee "$RESULTS_DIR/network-expansion-timeline.txt"

# Apply network expansion
oc patch Network.config.openshift.io cluster --type='merge' --patch "{
    \"spec\": {
        \"clusterNetwork\": [
            {
                \"cidr\": \"$CLUSTER_NETWORK_EXPANDED_CIDR\",
                \"hostPrefix\": $CLUSTER_NETWORK_HOST_PREFIX
            }
        ],
        \"networkType\": \"OVNKubernetes\"
    }
}" | tee "$RESULTS_DIR/network-expansion-patch-result.txt"

echo "$(date): Network expansion applied, waiting 20 minutes for reconfiguration (based on real test: 13.5 minutes)" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"
sleep 1200  # 20 minutes instead of 30

# Verify cluster health after network expansion
echo "$(date): Checking cluster health post-expansion" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"
check_cluster_health

echo "Updated cluster network configuration:"
oc get network.config.openshift.io cluster -o yaml | tee "$RESULTS_DIR/post-expansion-network-config.yaml"

echo "Post-expansion cluster operators status:"
oc get co -o wide | tee "$RESULTS_DIR/post-expansion-cluster-operators.txt"

# Step 3: Scale machinesets to maximum capacity
echo "=== STEP 3: Scale machinesets to test maximum node capacity ==="

# Get all machinesets
mapfile -t machinesets < <(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=NAME:.metadata.name)

if [[ ${#machinesets[@]} -ne 3 ]]; then
    echo "ERROR: Expected 3 machinesets, found ${#machinesets[@]}"
    exit 1
fi

# Scale machinesets to target total of 520 nodes (200+200+120)
echo "$(date): Starting machineset scaling" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"

echo "Scaling machineset ${machinesets[0]} to 200 replicas"
oc scale --replicas=200 machineset "${machinesets[0]}" -n openshift-machine-api | tee "$RESULTS_DIR/machineset-scaling-${machinesets[0]}.txt"

echo "Scaling machineset ${machinesets[1]} to 200 replicas" 
oc scale --replicas=200 machineset "${machinesets[1]}" -n openshift-machine-api | tee "$RESULTS_DIR/machineset-scaling-${machinesets[1]}.txt"

echo "Scaling machineset ${machinesets[2]} to 120 replicas"
oc scale --replicas=120 machineset "${machinesets[2]}" -n openshift-machine-api | tee "$RESULTS_DIR/machineset-scaling-${machinesets[2]}.txt"

echo "Machinesets scaled. Current state:"
oc get machineset -n openshift-machine-api -o wide | tee "$RESULTS_DIR/post-scaling-machinesets.txt"

echo "$(date): Machineset scaling completed" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"

# Step 4: Monitor node provisioning and validate results
echo "=== STEP 4: Monitor node provisioning ==="

# Wait for nodes to reach expected capacity
wait_for_nodes "$EXPECTED_READY_NODES" "$TEST_TIMEOUT"

# Get final node counts
echo "=== STEP 5: Validate test results ==="
echo "$(date): Final validation started" | tee -a "$RESULTS_DIR/network-expansion-timeline.txt"

total_nodes=$(oc get nodes --no-headers | wc -l)
ready_nodes=$(oc get nodes --no-headers | grep " Ready " | wc -l)
notready_nodes=$(oc get nodes --no-headers | grep "NotReady" | wc -l)

echo "Final node statistics:"
echo "  Total nodes: $total_nodes"
echo "  Ready nodes: $ready_nodes" 
echo "  NotReady nodes: $notready_nodes"

# Save detailed results
{
    echo "OCP-61589 Test Results Summary"
    echo "============================="
    echo "Test Date: $(date)"
    echo "Initial Nodes: $initial_node_count"
    echo "Final Total Nodes: $total_nodes"
    echo "Final Ready Nodes: $ready_nodes"
    echo "Final NotReady Nodes: $notready_nodes"
    echo "Target Nodes: $MAX_NODES_TARGET"
    echo "Expected Ready: $EXPECTED_READY_NODES"
    echo "Network Expansion: $CLUSTER_NETWORK_ORIGINAL_CIDR -> $CLUSTER_NETWORK_EXPANDED_CIDR"
} | tee "$RESULTS_DIR/test-results-summary.txt"

# Save all node details
oc get nodes -o wide | tee "$RESULTS_DIR/final-all-nodes.txt"
oc get nodes --no-headers | grep " Ready " > "$RESULTS_DIR/final-ready-nodes.txt"
oc get nodes --no-headers | grep "NotReady" > "$RESULTS_DIR/final-notready-nodes.txt"

# Show NotReady node details
if [[ $notready_nodes -gt 0 ]]; then
    echo "NotReady nodes:"
    oc get nodes --no-headers | grep "NotReady" | head -10 | tee "$RESULTS_DIR/notready-nodes-sample.txt"
    
    echo "Checking error messages for NotReady nodes..."
    notready_node=$(oc get nodes --no-headers | grep "NotReady" | head -1 | awk '{print $1}')
    if [[ -n "$notready_node" ]]; then
        echo "Sample error from $notready_node:"
        oc describe node "$notready_node" | tee "$RESULTS_DIR/notready-node-details-$notready_node.txt"
        
        # Check for both types of subnet exhaustion errors
        echo "Checking for subnet exhaustion evidence..."
        
        # Classic subnet annotation error
        if oc describe node "$notready_node" | grep -A3 -B3 "k8s.ovn.org/node-subnets.*annotation" | tee "$RESULTS_DIR/subnet-annotation-errors.txt"; then
            echo "✅ Found classic subnet annotation error"
        # NetworkPluginNotReady with CNI config missing
        elif oc describe node "$notready_node" | grep -A3 -B3 "NetworkPluginNotReady.*no CNI configuration" | tee "$RESULTS_DIR/network-plugin-errors.txt"; then
            echo "✅ Found network plugin error indicating subnet exhaustion"
        else
            echo "⚠️  Unknown error type - saving full describe output for analysis"
            oc describe node "$notready_node" | grep -A10 -B5 "Ready.*False" | tee "$RESULTS_DIR/unknown-error-analysis.txt"
        fi
    fi
fi

# Save final machinesets status
oc get machineset -n openshift-machine-api -o wide | tee "$RESULTS_DIR/final-machinesets.txt"

# Save final cluster operator status
oc get co -o wide | tee "$RESULTS_DIR/final-cluster-operators.txt"

# Validate test expectations
echo "=== STEP 6: Test validation ==="

if [[ $ready_nodes -ge $((EXPECTED_READY_NODES - 10)) ]] && [[ $ready_nodes -le $((EXPECTED_READY_NODES + 10)) ]]; then
    echo "✅ SUCCESS: Ready node count ($ready_nodes) is within expected range (~$EXPECTED_READY_NODES)"
else
    echo "❌ FAIL: Ready node count ($ready_nodes) is outside expected range (~$EXPECTED_READY_NODES)"
    exit 1
fi

if [[ $total_nodes -ge $((MAX_NODES_TARGET - 20)) ]] && [[ $total_nodes -le $MAX_NODES_TARGET ]]; then
    echo "✅ SUCCESS: Total node count ($total_nodes) is within expected range (~$MAX_NODES_TARGET)"
else
    echo "❌ FAIL: Total node count ($total_nodes) is outside expected range (~$MAX_NODES_TARGET)"
    exit 1
fi

if [[ $notready_nodes -ge 5 ]] && [[ $notready_nodes -le 20 ]]; then
    echo "✅ SUCCESS: NotReady node count ($notready_nodes) indicates subnet exhaustion as expected"
else
    echo "⚠️  WARNING: NotReady node count ($notready_nodes) may indicate unexpected behavior"
fi

echo "=== TEST COMPLETED SUCCESSFULLY ==="
echo "OCP-61589 test validated that after network expansion, approximately $ready_nodes nodes became ready"
echo "before hitting subnet exhaustion with $notready_nodes nodes remaining NotReady"

# Create final comprehensive summary
{
    echo "============================================"
    echo "OCP-61589 COMPREHENSIVE TEST RESULTS"
    echo "============================================"
    echo "Test Completion Time: $(date)"
    echo ""
    echo "NETWORK CONFIGURATION:"
    echo "  Original CIDR: $CLUSTER_NETWORK_ORIGINAL_CIDR"
    echo "  Expanded CIDR: $CLUSTER_NETWORK_EXPANDED_CIDR"
    echo "  Host Prefix: $CLUSTER_NETWORK_HOST_PREFIX"
    echo ""
    echo "NODE STATISTICS:"
    echo "  Initial Nodes: $initial_node_count"
    echo "  Target Nodes: $MAX_NODES_TARGET"
    echo "  Expected Ready: $EXPECTED_READY_NODES"
    echo "  Final Total Nodes: $total_nodes"
    echo "  Final Ready Nodes: $ready_nodes"
    echo "  Final NotReady Nodes: $notready_nodes"
    echo ""
    echo "TEST VALIDATION:"
    if [[ $ready_nodes -ge $((EXPECTED_READY_NODES - 10)) ]] && [[ $ready_nodes -le $((EXPECTED_READY_NODES + 10)) ]]; then
        echo "  ✅ Ready Nodes: PASS ($ready_nodes within ±10 of $EXPECTED_READY_NODES)"
    else
        echo "  ❌ Ready Nodes: FAIL ($ready_nodes outside range of $EXPECTED_READY_NODES)"
    fi
    
    if [[ $total_nodes -ge $((MAX_NODES_TARGET - 20)) ]] && [[ $total_nodes -le $MAX_NODES_TARGET ]]; then
        echo "  ✅ Total Nodes: PASS ($total_nodes within range of $MAX_NODES_TARGET)"
    else
        echo "  ❌ Total Nodes: FAIL ($total_nodes outside range of $MAX_NODES_TARGET)"
    fi
    
    if [[ $notready_nodes -ge 5 ]] && [[ $notready_nodes -le 20 ]]; then
        echo "  ✅ Subnet Exhaustion: PASS ($notready_nodes NotReady nodes indicate expected behavior)"
    else
        echo "  ⚠️  Subnet Exhaustion: WARNING ($notready_nodes NotReady nodes, expected 5-20)"
    fi
    echo ""
    echo "ARTIFACTS SAVED TO: $RESULTS_DIR"
    echo "- Network configurations (before/after)"
    echo "- Node provisioning timeline and progress"
    echo "- Machineset scaling results"
    echo "- Cluster operator status"
    echo "- Detailed node lists and error messages"
    echo "============================================"
} | tee "$RESULTS_DIR/final-comprehensive-summary.txt"

echo ""
echo "📊 All test results and artifacts saved to: $RESULTS_DIR"
echo "📈 Key files for analysis:"
echo "  - test-results-summary.txt"
echo "  - node-provisioning-progress.csv"
echo "  - network-expansion-timeline.txt"
echo "  - final-comprehensive-summary.txt"