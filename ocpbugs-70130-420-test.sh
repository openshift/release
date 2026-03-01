#!/bin/bash
set -euo pipefail
export KUBECONFIG=/home/sninganu/Work/2026/Feb/kubeconfig

echo "==================================================================="
echo "OCPBUGS-70130 Test Started: $(date)"
echo "==================================================================="
echo "Cluster: sn-bg7022-20 (OpenShift 4.20)"
echo "Testing OCPBUGS-70130 annotation behavior"
echo "Target: Scale to 100+ nodes to test annotation dependency"
echo "Expected: May show annotation dependency issues (pre-fix behavior)"

# Track initial state
INITIAL_READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
INITIAL_TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
echo "Initial state: $INITIAL_READY_NODES ready nodes out of $INITIAL_TOTAL_NODES total"

# Display current nodes
echo ""
echo "Current nodes:"
oc get nodes
echo ""

# Get the main machineset
MACHINESET="sn-bg7022-20-tx58d-worker-us-east-2a"
CURRENT_REPLICAS=$(oc get machineset $MACHINESET -n openshift-machine-api -o jsonpath='{.spec.replicas}')
TARGET_WORKERS=100  # Scale to 100 workers (103 total with 3 masters)

echo "Machineset: $MACHINESET"
echo "Current replicas: $CURRENT_REPLICAS"
echo "Target workers: $TARGET_WORKERS (total nodes: $((TARGET_WORKERS + 3)))"
echo ""

# Start monitoring in background
{
    MONITOR_START=$(date +%s)
    while true; do
        TIMESTAMP=$(date)
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - MONITOR_START))
        
        # Count node states
        TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
        READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
        NOT_READY_NODES=$(oc get nodes --no-headers | grep -c " NotReady " || echo 0)
        
        # Count annotation states
        NODES_WITHOUT_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' 2>/dev/null | grep -c "^[^ ]* $" || echo 0)
        NODES_WITH_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' 2>/dev/null | grep -c "^[^ ]* [^ ]*$" || echo 0)
        
        echo "$TIMESTAMP: NODES: Total=$TOTAL_NODES Ready=$READY_NODES NotReady=$NOT_READY_NODES (Elapsed: ${ELAPSED}s)"
        echo "$TIMESTAMP: ANNOTATIONS: WithAnnotation=$NODES_WITH_ANNOTATION WithoutAnnotation=$NODES_WITHOUT_ANNOTATION"
        
        # Check for nodes stuck without annotation (4.20 may have this issue)
        if [ $NODES_WITHOUT_ANNOTATION -gt 0 ] && [ $NOT_READY_NODES -gt 0 ]; then
            echo "$TIMESTAMP: WARNING: $NOT_READY_NODES nodes not ready, $NODES_WITHOUT_ANNOTATION missing remote-zone-migrated annotation"
            echo "$TIMESTAMP: ANALYSIS: This may indicate OCPBUGS-70130 issue exists in 4.20"
            
            # List specific nodes without annotation that are not ready
            echo "$TIMESTAMP: Nodes without annotation:"
            oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' 2>/dev/null | while read node ready annotation; do
                if [[ "$ready" == "False" && "$annotation" == "" ]]; then
                    echo "$TIMESTAMP:   $node (Ready=$ready, Annotation=missing)"
                fi
            done | head -10
        fi
        
        # Check for mass readiness events (indicates fix is working)
        if [ $READY_NODES -gt $((INITIAL_READY_NODES + 10)) ]; then
            READY_JUMP=$((READY_NODES - INITIAL_READY_NODES))
            if [ $READY_JUMP -gt 20 ]; then
                echo "$TIMESTAMP: ✅ MASS READINESS: $READY_NODES nodes ready - indicates fix may be present"
                echo "$TIMESTAMP: ANALYSIS: Rapid readiness despite annotation status"
            fi
        fi
        
        # Progress tracking
        if [ $READY_NODES -gt $INITIAL_READY_NODES ]; then
            ADDED_WORKERS=$((READY_NODES - INITIAL_READY_NODES))
            PROGRESS_PCT=$(echo "scale=1; $ADDED_WORKERS * 100 / ($TARGET_WORKERS - $CURRENT_REPLICAS)" | bc -l 2>/dev/null || echo "0")
            echo "$TIMESTAMP: PROGRESS: Added $ADDED_WORKERS/$((TARGET_WORKERS - CURRENT_REPLICAS)) workers (${PROGRESS_PCT}%)"
        fi
        
        # Exit monitoring if we've reached target and all are ready
        if [ $TOTAL_NODES -ge $((TARGET_WORKERS + 3)) ] && [ $NOT_READY_NODES -eq 0 ]; then
            echo "$TIMESTAMP: SUCCESS: Reached target nodes and all are ready"
            break
        fi
        
        # Alert if many nodes stuck without annotations
        if [ $NOT_READY_NODES -gt 10 ] && [ $NODES_WITHOUT_ANNOTATION -gt $NOT_READY_NODES ]; then
            echo "$TIMESTAMP: 🚨 ALERT: $NOT_READY_NODES nodes stuck NotReady with missing annotations"
            echo "$TIMESTAMP: ANALYSIS: This strongly indicates OCPBUGS-70130 issue in 4.20"
        fi
        
        # Timeout after 45 minutes
        if [ $ELAPSED -gt 2700 ]; then
            echo "$TIMESTAMP: TIMEOUT: Monitoring stopped after 45 minutes"
            break
        fi
        
        sleep 30
    done
    
    # Final analysis
    FINAL_TOTAL=$(oc get nodes --no-headers | wc -l)
    FINAL_READY=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
    FINAL_NOT_READY=$(oc get nodes --no-headers | grep -c " NotReady " || echo 0)
    FINAL_WITH_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' 2>/dev/null | grep -c "^[^ ]* [^ ]*$" || echo 0)
    FINAL_WITHOUT_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' 2>/dev/null | grep -c "^[^ ]* $" || echo 0)
    
    echo "========== FINAL OCPBUGS-70130 4.20 Test Results =========="
    echo "$(date): FINAL CLUSTER STATE:"
    echo "$(date):   Total Nodes: $FINAL_TOTAL"
    echo "$(date):   Ready Nodes: $FINAL_READY"
    echo "$(date):   NotReady Nodes: $FINAL_NOT_READY"
    echo "$(date): FINAL ANNOTATION STATE:"
    echo "$(date):   With remote-zone-migrated: $FINAL_WITH_ANNOTATION"
    echo "$(date):   Without annotation: $FINAL_WITHOUT_ANNOTATION"
    echo "$(date): TEST SCOPE: Scaled from $INITIAL_READY_NODES to $FINAL_READY ready nodes"
    
    # Test assessment for 4.20
    if [ $FINAL_NOT_READY -eq 0 ] && [ $FINAL_TOTAL -ge $((TARGET_WORKERS + 3)) ]; then
        echo "$(date): ✅ SUCCESS: All nodes ready - OCPBUGS-70130 fix may be working on 4.20!"
        echo "$(date): ✅ ANALYSIS: Rapid scaling to $FINAL_TOTAL nodes completed without issues"
    elif [ $FINAL_NOT_READY -gt 10 ] && [ $FINAL_WITHOUT_ANNOTATION -gt $FINAL_NOT_READY ]; then
        echo "$(date): ❌ CONFIRMED: $FINAL_NOT_READY nodes stuck, $FINAL_WITHOUT_ANNOTATION missing annotations"
        echo "$(date): ❌ ANALYSIS: OCPBUGS-70130 issue exists on 4.20 - annotation dependency confirmed"
    elif [ $FINAL_NOT_READY -gt 5 ] && [ $FINAL_WITHOUT_ANNOTATION -gt 5 ]; then
        echo "$(date): ⚠️  PARTIAL ISSUE: $FINAL_NOT_READY nodes stuck, annotation dependency may exist"
    else
        echo "$(date): ⚠️  INCONCLUSIVE: $FINAL_NOT_READY not ready, may need more time or different test"
    fi
    
    echo "$(date): 🔄 COMPARISON: Will compare with 4.21 test results"
    echo "$(date): 📊 4.20 vs 4.21 annotation behavior analysis pending"
    echo "========================================================="
} > "OCPBUGS-70130-420-test-$(date +%Y%m%d-%H%M%S).log" 2>&1 &

MONITOR_PID=$!
echo "Started monitoring (PID: $MONITOR_PID), logs in: OCPBUGS-70130-420-test-$(date +%Y%m%d-%H%M%S).log"

# Start the scaling
echo ""
echo "$(date): Starting scale operation..."
oc scale machineset $MACHINESET --replicas=$TARGET_WORKERS -n openshift-machine-api

echo "$(date): Scale command issued!"
echo "$(date): Scaling from $CURRENT_REPLICAS to $TARGET_WORKERS workers"
echo "$(date): Monitor with: tail -f OCPBUGS-70130-420-test-*.log"
echo ""
echo "Test is running in background. Monitor the log file to see progress."
echo "Expected behavior: May see nodes stuck NotReady due to missing annotations (4.20 pre-fix)."