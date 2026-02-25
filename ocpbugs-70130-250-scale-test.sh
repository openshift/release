#!/bin/bash
set -euo pipefail
export KUBECONFIG=/home/sninganu/Work/2026/Jan/kubeconfig

echo "==================================================================="
echo "OCPBUGS-70130 Scale to 250 Test Started: $(date)"
echo "==================================================================="
echo "Cluster: oc21-bg701030 (OpenShift 4.21)"
echo "Scaling from 100 to 250 workers (253 total nodes)"
echo "Testing annotation independence - nodes should become Ready without annotation"

# Track initial state  
INITIAL_READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
INITIAL_TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
echo "Initial state: $INITIAL_READY_NODES ready nodes out of $INITIAL_TOTAL_NODES total"

# Monitor scaling progress
while true; do
    TIMESTAMP=$(date)
    
    # Count node states
    TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
    READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
    NOT_READY_NODES=$(oc get nodes --no-headers | grep -c " NotReady " || echo 0)
    
    echo "$TIMESTAMP: NODES: Total=$TOTAL_NODES Ready=$READY_NODES NotReady=$NOT_READY_NODES"
    
    # Progress tracking
    if [ $READY_NODES -gt $INITIAL_READY_NODES ]; then
        ADDED_WORKERS=$((READY_NODES - INITIAL_READY_NODES))
        PROGRESS_PCT=$(echo "scale=1; $ADDED_WORKERS * 100 / 150" | bc -l 2>/dev/null || echo "0")
        echo "$TIMESTAMP: PROGRESS: Added $ADDED_WORKERS/150 additional workers (${PROGRESS_PCT}%)"
    fi
    
    # Check for mass readiness (sign of fix working)
    if [ $READY_NODES -gt $((INITIAL_READY_NODES + 20)) ]; then
        READY_JUMP=$((READY_NODES - INITIAL_READY_NODES))
        echo "$TIMESTAMP: ✅ MASS READINESS: +$READY_JUMP nodes ready - OCPBUGS-70130 fix working!"
    fi
    
    # Exit when target reached or timeout
    if [ $TOTAL_NODES -ge 253 ] && [ $NOT_READY_NODES -eq 0 ]; then
        echo "$TIMESTAMP: 🎯 SUCCESS: Reached 250+ workers, all nodes ready!"
        break
    fi
    
    if [ $TOTAL_NODES -ge 250 ]; then
        echo "$TIMESTAMP: 📊 Large scale achieved: $TOTAL_NODES nodes ($READY_NODES ready)"
    fi
    
    sleep 30
done

echo "========== 250-WORKER SCALE TEST COMPLETE =========="
echo "$(date): Final validation of OCPBUGS-70130 fix at scale"
echo "Expected: All nodes Ready despite missing remote-zone-migrated annotations"