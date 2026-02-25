# OCPBUGS-70130 Master Branch Test Plan

## Objective
Test scaling to 400-500 nodes on master branch (without PR #2980 fix) to demonstrate the original issue and compare with the fixed branch results.

## Test Environment
- **Cluster**: New cluster with master branch OVN-Kubernetes (contains migration code)
- **Target Scale**: 400-500 nodes
- **Expected Behavior**: Nodes should get stuck without `k8s.ovn.org/remote-zone-migrated` annotation

## Comparison Summary

### Current State
- **Fixed Branch (421-BM-dptah)**: Successfully scaled to 400 nodes with mass readiness events
- **Master Branch**: Contains all the IC zone migration code that should cause issues

### Files that Should Cause Issues on Master
1. **`go-controller/pkg/util/node_annotations.go:133`**
   ```go
   OvnNodeMigratedZoneName = "k8s.ovn.org/remote-zone-migrated"
   ```

2. **`base_network_controller.go:1049`**
   ```go
   if bnc.zone == types.OvnDefaultZone {
       return !util.HasNodeMigratedZone(node)  // HACK logic
   }
   ```

3. **`default_node_network_controller.go`**
   - 100+ lines of migration HACK code
   - Waits for remote ovnkube-controller readiness
   - Sets migration annotations

## Test Commands

### 1. Verify Cluster Connection
```bash
export KUBECONFIG=/path/to/master-branch-kubeconfig
oc get nodes
oc get machinesets -n openshift-machine-api
```

### 2. Create Monitoring Script
```bash
# Create enhanced monitoring for master branch test
cat > /tmp/ocpbugs-70130-master-test.sh << 'EOF'
#!/bin/bash
set -euo pipefail

echo "==================================================================="
echo "OCPBUGS-70130 Master Branch Test Started: $(date)"
echo "==================================================================="
echo "Testing ORIGINAL issue - nodes should get stuck without annotation"
echo "Master branch contains IC zone migration HACK code"

# Track initial state
INITIAL_READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
echo "Initial ready nodes: $INITIAL_READY_NODES"

while true; do
    TIMESTAMP=$(date)
    
    # Count node states
    TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
    READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
    NOT_READY_NODES=$(oc get nodes --no-headers | grep -c " NotReady " || echo 0)
    
    # Count annotation states
    NODES_WITHOUT_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | grep -c "^[^ ]* $" || echo 0)
    NODES_WITH_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | grep -c "^[^ ]* [^ ]*$" || echo 0)
    
    echo "$TIMESTAMP: NODES: Total=$TOTAL_NODES Ready=$READY_NODES NotReady=$NOT_READY_NODES"
    echo "$TIMESTAMP: ANNOTATIONS: WithAnnotation=$NODES_WITH_ANNOTATION WithoutAnnotation=$NODES_WITHOUT_ANNOTATION"
    
    # Look for the ORIGINAL ISSUE: nodes stuck without annotation
    if [ $NOT_READY_NODES -gt 0 ] && [ $NODES_WITHOUT_ANNOTATION -gt 0 ]; then
        echo "$TIMESTAMP: ⚠️  ORIGINAL ISSUE DETECTED: $NOT_READY_NODES nodes not ready, $NODES_WITHOUT_ANNOTATION missing annotation"
        echo "$TIMESTAMP: 🐛 This demonstrates OCPBUGS-70130 - nodes stuck without remote-zone-migrated annotation"
        
        # List specific nodes stuck without annotation
        echo "$TIMESTAMP: Nodes stuck without annotation:"
        oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | while read node ready annotation; do
            if [[ "$ready" == "False" && "$annotation" == "" ]]; then
                echo "$TIMESTAMP:   $node (Ready=$ready, Annotation=missing) ← STUCK NODE"
            fi
        done
    fi
    
    # Progress tracking
    if [ $READY_NODES -gt $INITIAL_READY_NODES ]; then
        ADDED_WORKERS=$((READY_NODES - INITIAL_READY_NODES))
        echo "$TIMESTAMP: PROGRESS: Added $ADDED_WORKERS workers"
    fi
    
    # Exit condition: either all ready OR stuck for too long
    if [ $NOT_READY_NODES -eq 0 ]; then
        echo "$TIMESTAMP: All nodes ready - test completed (unexpected if issue exists)"
        break
    fi
    
    sleep 30
done

echo "========== MASTER BRANCH TEST RESULTS =========="
echo "$(date): EXPECTED: Nodes should get stuck without remote-zone-migrated annotation"
echo "$(date): ACTUAL: Check logs above for stuck nodes"
EOF

chmod +x /tmp/ocpbugs-70130-master-test.sh
```

### 3. Scale Up Test
```bash
# Get machineset name
MACHINESET=$(oc get machinesets -n openshift-machine-api -o name | head -1 | cut -d/ -f2)
echo "Using machineset: $MACHINESET"

# Start monitoring in background
/tmp/ocpbugs-70130-master-test.sh > ocpbugs-70130-master-test-$(date +%Y%m%d-%H%M%S).log 2>&1 &
MONITOR_PID=$!

# Scale to 400-500 nodes (adjust based on current cluster size)
# If you have 6 nodes now, add 394-494 workers
CURRENT_WORKERS=$(oc get machineset $MACHINESET -n openshift-machine-api -o jsonpath='{.spec.replicas}')
TARGET_WORKERS=$((CURRENT_WORKERS + 400))
echo "Scaling from $CURRENT_WORKERS to $TARGET_WORKERS replicas"

oc scale machineset $MACHINESET --replicas=$TARGET_WORKERS -n openshift-machine-api

# Wait and monitor
echo "Monitoring scaling progress. Check log file for details..."
wait $MONITOR_PID
```

## Expected Results on Master Branch

### What Should Happen (Demonstrating Original Issue)
1. **Initial Scaling**: New worker nodes will start joining
2. **Annotation Problem**: Nodes will get stuck without `k8s.ovn.org/remote-zone-migrated` annotation  
3. **Readiness Issues**: Many nodes will remain in `NotReady` state
4. **Evidence of Bug**: Log will show "ORIGINAL ISSUE DETECTED" messages
5. **Stuck Nodes**: Specific nodes listed as "STUCK NODE" in logs

### Evidence This Would Collect
- Nodes in `NotReady` state missing the annotation
- Timestamps showing when nodes get stuck
- Comparison data for Riccardo's analysis

## Key Differences vs Fixed Branch

| Aspect | Fixed Branch (421-BM-dptah) | Master Branch (Expected) |
|--------|------------------------------|---------------------------|
| **Node Readiness** | Mass readiness events, all 400 ready | Nodes get stuck, many NotReady |
| **Annotations** | Clean annotation handling | Missing remote-zone-migrated annotations |
| **Scaling Time** | Fast scaling completion | Slow/stuck scaling |
| **Final State** | ✅ 400/400 ready | ❌ Many stuck in NotReady |

## Files to Check for Master Branch OVN-K

Verify these files contain the migration code:
```bash
# Should show the annotation constant
grep -r "remote-zone-migrated" /path/to/ovn-kubernetes/

# Should show HACK comments
grep -r "HACK" /path/to/ovn-kubernetes/go-controller/pkg/ovn/

# Should show migration field
grep -A5 -B5 "migrated bool" /path/to/ovn-kubernetes/
```

This test will provide the before/after comparison Riccardo requested to validate that PR #2980 truly fixes the OCPBUGS-70130 issue.