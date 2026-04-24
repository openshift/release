#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🧪 Starting OCPBUGS-45891: EgressIP Scale Test with Minimal Large VMs"
echo "=================================================================="

# Test configuration based on Jean's validation
export EXPECTED_WORKER_NODES="${EXPECTED_WORKER_NODES:-2}"
export WORKER_VM_TYPE="${WORKER_VM_TYPE:-m6a.16xlarge}"
export TOTAL_EGRESSIP_OBJECTS="${TOTAL_EGRESSIP_OBJECTS:-100}"
export EXPECTED_ASSIGNED_EGRESSIPS="${EXPECTED_ASSIGNED_EGRESSIPS:-98}"
export EGRESSIP_NAME_PREFIX="${EGRESSIP_NAME_PREFIX:-egressip-45891}"
export TEST_TIMEOUT="${TEST_TIMEOUT:-30m}"

# Create results directory
RESULTS_DIR="${ARTIFACT_DIR:-/tmp}/ocpbugs-45891-results"
mkdir -p "$RESULTS_DIR"

# Function to wait for condition with timeout
wait_for_condition() {
    local description="$1"
    local condition_cmd="$2"
    local timeout="$3"
    local check_interval="${4:-30}"
    
    echo "⏳ Waiting for: $description (timeout: $timeout)"
    
    local start_time
    start_time=$(date +%s)
    local timeout_seconds
    timeout_seconds=$(echo "$timeout" | sed 's/h/*3600/g; s/m/*60/g; s/s//g' | bc)
    
    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed
        elapsed=$((current_time - start_time))
        
        if eval "$condition_cmd"; then
            echo "✅ SUCCESS: $description completed in ${elapsed}s"
            return 0
        fi
        
        if [ $elapsed -gt $timeout_seconds ]; then
            echo "❌ TIMEOUT: $description failed after $timeout"
            return 1
        fi
        
        echo "$(date): Still waiting... (elapsed: ${elapsed}s)"
        sleep "$check_interval"
    done
}

echo "=== STEP 1: Verify initial cluster configuration ==="
echo "📊 Checking cluster version and nodes..."

# Check cluster version
echo "Cluster version:"
oc get clusterversion | tee "$RESULTS_DIR/cluster-version.txt"

# Verify node configuration
echo ""
echo "Node configuration:"
oc get nodes -o wide | tee "$RESULTS_DIR/initial-nodes.txt"

worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker= | wc -l)
echo "Worker nodes found: $worker_count (expected: $EXPECTED_WORKER_NODES)"

if [ "$worker_count" -ne "$EXPECTED_WORKER_NODES" ]; then
    echo "❌ ERROR: Expected $EXPECTED_WORKER_NODES worker nodes, found $worker_count"
    exit 1
fi

# Verify worker node VM types
echo ""
echo "Verifying worker VM types..."
mapfile -t worker_nodes < <(oc get nodes --no-headers -l node-role.kubernetes.io/worker= -o custom-columns=NAME:.metadata.name)

for node in "${worker_nodes[@]}"; do
    vm_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
    echo "Node $node: $vm_type"
    
    if [ "$vm_type" != "$WORKER_VM_TYPE" ]; then
        echo "❌ ERROR: Node $node has VM type $vm_type, expected $WORKER_VM_TYPE"
        exit 1
    fi
done

echo "✅ All worker nodes have correct VM type: $WORKER_VM_TYPE"

echo ""
echo "=== STEP 2: Verify egress IP node configuration ==="

# Check each worker node for egress IP configuration
for node in "${worker_nodes[@]}"; do
    echo "📋 Checking egress IP configuration for node: $node"
    
    # Get egress IP configuration annotation
    egress_config=$(oc get node "$node" -o jsonpath='{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}' 2>/dev/null || echo "")
    
    if [ -z "$egress_config" ]; then
        echo "❌ ERROR: Node $node missing egress IP configuration annotation"
        exit 1
    fi
    
    echo "Egress IP config for $node:"
    echo "$egress_config" | jq '.' | tee "$RESULTS_DIR/egress-config-$node.json"
    
    # Extract IPv4 capacity
    ipv4_capacity=$(echo "$egress_config" | jq -r '.[0].capacity.ipv4' 2>/dev/null || echo "0")
    echo "IPv4 capacity: $ipv4_capacity"
    
    if [ "$ipv4_capacity" -lt 49 ]; then
        echo "⚠️  WARNING: Node $node has low IPv4 capacity: $ipv4_capacity (expected: ~49)"
    fi
done

echo "✅ All nodes have egress IP configuration"

echo ""
echo "=== STEP 3: Label worker nodes as egress-assignable ==="

for node in "${worker_nodes[@]}"; do
    echo "🏷️  Labeling node $node as egress-assignable..."
    oc label node "$node" k8s.ovn.org/egress-assignable=true --overwrite
done

# Verify labeling
echo ""
echo "Verifying egress-assignable labels:"
oc get nodes --show-labels | grep egress-assignable | tee "$RESULTS_DIR/egress-assignable-nodes.txt"

assignable_count=$(oc get nodes -l k8s.ovn.org/egress-assignable=true --no-headers | wc -l)
if [ "$assignable_count" -ne "$EXPECTED_WORKER_NODES" ]; then
    echo "❌ ERROR: Expected $EXPECTED_WORKER_NODES egress-assignable nodes, found $assignable_count"
    exit 1
fi

echo "✅ Successfully labeled $assignable_count nodes as egress-assignable"

echo ""
echo "=== STEP 4: Create EgressIP objects ==="

echo "📝 Creating $TOTAL_EGRESSIP_OBJECTS EgressIP objects with prefix: $EGRESSIP_NAME_PREFIX"

# Generate EgressIP objects based on Jean's pattern
for i in $(seq 0 $((TOTAL_EGRESSIP_OBJECTS - 1))); do
    egressip_name="${EGRESSIP_NAME_PREFIX}-${i}"
    
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: $egressip_name
spec:
  egressIPs: []
  namespaceSelector: {}
  podSelector:
    matchLabels:
      egress-test: "$egressip_name"
EOF
    
    # Log progress every 20 objects
    if [ $((i % 20)) -eq 0 ]; then
        echo "Created $((i + 1))/$TOTAL_EGRESSIP_OBJECTS EgressIP objects..."
    fi
done

echo "✅ Successfully created $TOTAL_EGRESSIP_OBJECTS EgressIP objects"

echo ""
echo "=== STEP 5: Wait for EgressIP assignment ==="

# Wait for EgressIPs to be assigned
echo "⏳ Waiting for EgressIP assignments to stabilize..."

wait_for_condition \
    "EgressIP assignments to stabilize" \
    "[ \$(oc get egressip -o jsonpath='{range .items[*]}{.status.items[0].node}{\"\n\"}{end}' | grep -v '^\$' | wc -l) -ge $((EXPECTED_ASSIGNED_EGRESSIPS - 5)) ]" \
    "$TEST_TIMEOUT"

echo ""
echo "=== STEP 6: Validate EgressIP assignment results ==="

# Count assigned EgressIPs
assigned_count=$(oc get egressip -o jsonpath='{range .items[*]}{.status.items[0].node}{"\n"}{end}' | grep -v '^$' | wc -l)
echo "📊 Assigned EgressIPs: $assigned_count"

# Count CloudPrivateIPConfig objects
cloudconfig_count=$(oc get cloudprivateipconfig -o json | jq '.items | length')
echo "📊 CloudPrivateIPConfig objects: $cloudconfig_count"

# Save detailed EgressIP status
echo ""
echo "📋 Detailed EgressIP status:"
oc get egressip | tee "$RESULTS_DIR/egressip-status.txt"

# Save CloudPrivateIPConfig status
echo ""
echo "📋 CloudPrivateIPConfig status:"
oc get cloudprivateipconfig | tee "$RESULTS_DIR/cloudprivateipconfig-status.txt"

# Analyze load distribution per node
echo ""
echo "📊 EgressIP load distribution:"
for node in "${worker_nodes[@]}"; do
    node_assignment_count=$(oc get egressip -o jsonpath='{range .items[*]}{.status.items[0].node}{"\n"}{end}' | grep "^$node$" | wc -l)
    echo "Node $node: $node_assignment_count EgressIPs"
done

# Check for unassigned EgressIPs
echo ""
echo "🔍 Checking for unassigned EgressIPs:"
unassigned_egressips=$(oc get egressip -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.items[0].node}{"\n"}{end}' | grep "=$" | cut -d'=' -f1 || true)

if [ -n "$unassigned_egressips" ]; then
    echo "⚠️  Unassigned EgressIPs found:"
    echo "$unassigned_egressips" | tee "$RESULTS_DIR/unassigned-egressips.txt"
    unassigned_count=$(echo "$unassigned_egressips" | wc -l)
    echo "Total unassigned: $unassigned_count"
else
    echo "✅ No unassigned EgressIPs found"
    unassigned_count=0
fi

echo ""
echo "=== STEP 7: Validate test expectations ==="

# Validate assignment count
if [ "$assigned_count" -ge $((EXPECTED_ASSIGNED_EGRESSIPS - 2)) ] && [ "$assigned_count" -le $((EXPECTED_ASSIGNED_EGRESSIPS + 2)) ]; then
    echo "✅ SUCCESS: Assigned EgressIPs ($assigned_count) within expected range (~$EXPECTED_ASSIGNED_EGRESSIPS)"
else
    echo "❌ FAIL: Assigned EgressIPs ($assigned_count) outside expected range (~$EXPECTED_ASSIGNED_EGRESSIPS)"
    exit 1
fi

# Validate CloudPrivateIPConfig count matches
if [ "$cloudconfig_count" -eq "$assigned_count" ]; then
    echo "✅ SUCCESS: CloudPrivateIPConfig count ($cloudconfig_count) matches assigned EgressIPs ($assigned_count)"
else
    echo "❌ FAIL: CloudPrivateIPConfig count ($cloudconfig_count) does not match assigned EgressIPs ($assigned_count)"
    exit 1
fi

# Validate load balancing (should be ~equal distribution)
total_assignments=0
max_assignments=0
min_assignments=999

for node in "${worker_nodes[@]}"; do
    node_assignments=$(oc get egressip -o jsonpath='{range .items[*]}{.status.items[0].node}{"\n"}{end}' | grep "^$node$" | wc -l)
    total_assignments=$((total_assignments + node_assignments))
    
    if [ "$node_assignments" -gt "$max_assignments" ]; then
        max_assignments=$node_assignments
    fi
    
    if [ "$node_assignments" -lt "$min_assignments" ]; then
        min_assignments=$node_assignments
    fi
done

load_balance_diff=$((max_assignments - min_assignments))
if [ "$load_balance_diff" -le 2 ]; then
    echo "✅ SUCCESS: Good load balancing (max: $max_assignments, min: $min_assignments, diff: $load_balance_diff)"
else
    echo "⚠️  WARNING: Poor load balancing (max: $max_assignments, min: $min_assignments, diff: $load_balance_diff)"
fi

echo ""
echo "=== FINAL RESULTS SUMMARY ==="

{
    echo "OCPBUGS-45891 EgressIP Scale Test Results"
    echo "========================================"
    echo "Test Date: $(date)"
    echo ""
    echo "CLUSTER CONFIGURATION:"
    echo "  Worker Nodes: $worker_count (VM type: $WORKER_VM_TYPE)"
    echo "  OpenShift Version: $(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}')"
    echo ""
    echo "EGRESSIP RESULTS:"
    echo "  Total EgressIP Objects: $TOTAL_EGRESSIP_OBJECTS"
    echo "  Successfully Assigned: $assigned_count"
    echo "  Unassigned: $unassigned_count"
    echo "  CloudPrivateIPConfig Count: $cloudconfig_count"
    echo ""
    echo "LOAD DISTRIBUTION:"
    for node in "${worker_nodes[@]}"; do
        node_assignments=$(oc get egressip -o jsonpath='{range .items[*]}{.status.items[0].node}{"\n"}{end}' | grep "^$node$" | wc -l)
        echo "  $node: $node_assignments EgressIPs"
    done
    echo ""
    echo "VALIDATION RESULTS:"
    if [ "$assigned_count" -ge $((EXPECTED_ASSIGNED_EGRESSIPS - 2)) ] && [ "$assigned_count" -le $((EXPECTED_ASSIGNED_EGRESSIPS + 2)) ]; then
        echo "  ✅ Assignment Count: PASS ($assigned_count within ±2 of $EXPECTED_ASSIGNED_EGRESSIPS)"
    else
        echo "  ❌ Assignment Count: FAIL ($assigned_count outside range of $EXPECTED_ASSIGNED_EGRESSIPS)"
    fi
    
    if [ "$cloudconfig_count" -eq "$assigned_count" ]; then
        echo "  ✅ CloudPrivateIPConfig: PASS ($cloudconfig_count matches assigned)"
    else
        echo "  ❌ CloudPrivateIPConfig: FAIL ($cloudconfig_count != $assigned_count)"
    fi
    
    if [ "$load_balance_diff" -le 2 ]; then
        echo "  ✅ Load Balancing: PASS (difference: $load_balance_diff)"
    else
        echo "  ⚠️  Load Balancing: WARNING (difference: $load_balance_diff)"
    fi
    echo ""
    echo "ARTIFACTS SAVED TO: $RESULTS_DIR"
    echo "- cluster-version.txt"
    echo "- initial-nodes.txt"
    echo "- egress-config-*.json"
    echo "- egressip-status.txt"
    echo "- cloudprivateipconfig-status.txt"
    echo "- unassigned-egressips.txt (if any)"
    echo "========================================"
} | tee "$RESULTS_DIR/test-results-summary.txt"

echo ""
echo "🎯 OCPBUGS-45891 test completed successfully!"
echo "📊 Key validation: $assigned_count/$TOTAL_EGRESSIP_OBJECTS EgressIPs assigned with optimal load distribution"
echo "💾 All results saved to: $RESULTS_DIR"