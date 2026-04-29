#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Environment variables with defaults
export EXPECTED_WORKER_NODES="${EXPECTED_WORKER_NODES:-5}"
export LOADBALANCER_SERVICES="${LOADBALANCER_SERVICES:-500}"
export BACKEND_PODS="${BACKEND_PODS:-1000}"
export SYNC_TIME_THRESHOLD="${SYNC_TIME_THRESHOLD:-10}"  # seconds
export TEST_TIMEOUT="${TEST_TIMEOUT:-45m}"
export TEST_NAMESPACE="${TEST_NAMESPACE:-ovn-sync-test}"

echo "🧪 Starting OVN Service Sync Performance Test"
echo "==============================================="
echo "Target configuration:"
echo "  Expected workers: $EXPECTED_WORKER_NODES"
echo "  LoadBalancer services: $LOADBALANCER_SERVICES"
echo "  Backend pods: $BACKEND_PODS"
echo "  Sync time threshold: ${SYNC_TIME_THRESHOLD}s"
echo "  Test timeout: $TEST_TIMEOUT"

# Create results directory
RESULTS_DIR="${ARTIFACT_DIR:-/tmp}/ovn-service-sync-results"
mkdir -p "$RESULTS_DIR"

# Function to check if cluster has expected number of worker nodes
wait_for_workers() {
    echo "=== STEP 1: Verify cluster configuration ==="
    echo "Waiting for $EXPECTED_WORKER_NODES worker nodes to be ready..."
    local timeout=600  # 10 minutes
    local start_time
    start_time=$(date +%s)
    
    while true; do
        local ready_workers
        ready_workers=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker | grep " Ready" | wc -l)
        echo "Ready workers: $ready_workers/$EXPECTED_WORKER_NODES"
        
        if [[ $ready_workers -ge $EXPECTED_WORKER_NODES ]]; then
            echo "✅ All $EXPECTED_WORKER_NODES worker nodes are ready"
            return 0
        fi
        
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [[ $elapsed -gt $timeout ]]; then
            echo "❌ Timeout waiting for worker nodes"
            oc get nodes
            return 1
        fi
        
        sleep 30
    done
}

# Function to create test workload
create_test_workload() {
    echo ""
    echo "=== STEP 2: Create test workload ==="
    echo "Creating test namespace..."
    oc create namespace $TEST_NAMESPACE || true
    oc project $TEST_NAMESPACE
    
    echo "Creating $BACKEND_PODS backend pods..."
    cat > "$RESULTS_DIR/backend-deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-pods
  namespace: $TEST_NAMESPACE
spec:
  replicas: $BACKEND_PODS
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.20
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 50m
            memory: 64Mi
EOF

    echo "Deploying backend pods..."
    oc apply -f "$RESULTS_DIR/backend-deployment.yaml"
    
    # Wait for backend pods to be ready
    echo "Waiting for backend pods to be ready..."
    oc wait --for=condition=available --timeout=15m deployment/backend-pods -n $TEST_NAMESPACE
    
    # Wait a bit more for all pods to be fully running
    echo "Waiting for all backend pods to be running..."
    local max_wait=300  # 5 minutes
    local wait_time=0
    while [[ $wait_time -lt $max_wait ]]; do
        local running_pods
        running_pods=$(oc get pods -n $TEST_NAMESPACE -l app=backend --no-headers | grep " Running" | wc -l)
        echo "Running backend pods: $running_pods/$BACKEND_PODS"
        
        if [[ $running_pods -ge $((BACKEND_PODS * 95 / 100)) ]]; then  # At least 95% running
            echo "✅ Sufficient backend pods are running"
            break
        fi
        
        sleep 10
        wait_time=$((wait_time + 10))
    done
    
    # Create LoadBalancer services
    echo "Creating $LOADBALANCER_SERVICES LoadBalancer services..."
    local start_time
    start_time=$(date +%s)
    
    for i in $(seq 1 $LOADBALANCER_SERVICES); do
        cat > "$RESULTS_DIR/service-${i}.yaml" << EOF
apiVersion: v1
kind: Service
metadata:
  name: lb-service-${i}
  namespace: $TEST_NAMESPACE
spec:
  type: LoadBalancer
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
EOF
        oc apply -f "$RESULTS_DIR/service-${i}.yaml"
        
        # Progress indicator
        if [[ $((i % 50)) -eq 0 ]]; then
            local current_time
            current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            echo "Created $i/$LOADBALANCER_SERVICES services (${elapsed}s elapsed)..."
        fi
    done
    
    local end_time
    end_time=$(date +%s)
    local total_creation_time=$((end_time - start_time))
    echo "✅ Created $LOADBALANCER_SERVICES LoadBalancer services in ${total_creation_time}s"
    
    # Wait for services to be processed by OVN
    echo "Waiting 60 seconds for services to be processed by OVN..."
    sleep 60
    
    # Verify workload
    local final_services
    final_services=$(oc get services -n $TEST_NAMESPACE --no-headers | wc -l)
    local final_pods
    final_pods=$(oc get pods -n $TEST_NAMESPACE --no-headers | grep " Running" | wc -l)
    echo "✅ Final workload: $final_services services, $final_pods running pods"
    
    # Save workload info to results
    {
        echo "Workload Creation Summary:"
        echo "  Services created: $final_services"
        echo "  Running pods: $final_pods"
        echo "  Creation time: ${total_creation_time}s"
        echo "  Timestamp: $(date)"
    } | tee "$RESULTS_DIR/workload-summary.txt"
}

# Function to test OVN service sync performance
test_ovn_service_sync() {
    echo ""
    echo "=== STEP 3: Test OVN service sync performance ==="
    
    # Get all ovnkube-node pods on worker nodes
    local worker_ovnkube_pods
    mapfile -t worker_ovnkube_pods < <(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o json | python3 -c "
import json
import sys
data = json.load(sys.stdin)
for item in data['items']:
    node_name = item['spec']['nodeName']
    pod_name = item['metadata']['name']
    # Check if node is a worker
    try:
        import subprocess
        result = subprocess.run(['oc', 'get', 'node', node_name, '-o', 'jsonpath={.metadata.labels.node-role\.kubernetes\.io/worker}'], 
                              capture_output=True, text=True, check=False)
        if result.stdout.strip():  # Has worker label
            print(pod_name)
    except:
        pass
")
    
    if [[ ${#worker_ovnkube_pods[@]} -eq 0 ]]; then
        echo "❌ ERROR: No ovnkube-node pods found on worker nodes"
        return 1
    fi
    
    echo "Found ${#worker_ovnkube_pods[@]} ovnkube-node pods on worker nodes: ${worker_ovnkube_pods[*]}"
    
    # Test results storage
    local sync_results=()
    local failed_syncs=0
    local test_count=0
    
    # Test up to 3 pods (or all if less than 3)
    local pods_to_test=${#worker_ovnkube_pods[@]}
    if [[ $pods_to_test -gt 3 ]]; then
        pods_to_test=3
    fi
    
    for i in $(seq 0 $((pods_to_test - 1))); do
        local pod=${worker_ovnkube_pods[$i]}
        ((test_count++))
        
        echo ""
        echo "--- Testing service sync for pod $test_count/$pods_to_test: $pod ---"
        
        # Get pod node for identification
        local node_name
        node_name=$(oc get pod "$pod" -n openshift-ovn-kubernetes -o jsonpath='{.spec.nodeName}')
        echo "Node: $node_name"
        
        # Record pre-restart timestamp
        local restart_timestamp
        restart_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        
        # Restart the ovnkube-node pod
        echo "Restarting ovnkube-node pod..."
        oc delete pod "$pod" -n openshift-ovn-kubernetes
        
        # Wait for pod to be deleted
        echo "Waiting for pod to be deleted..."
        local delete_wait=0
        while oc get pod "$pod" -n openshift-ovn-kubernetes >/dev/null 2>&1 && [[ $delete_wait -lt 60 ]]; do
            sleep 5
            delete_wait=$((delete_wait + 5))
        done
        
        # Wait for new pod to appear and be ready
        echo "Waiting for new ovnkube-node pod to be ready..."
        local ready_wait=0
        local new_pod=""
        while [[ $ready_wait -lt 300 ]]; do  # 5 minutes max wait
            new_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName="$node_name" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
            if [[ -n "$new_pod" ]]; then
                # Check if pod is ready
                local pod_ready
                pod_ready=$(oc get pod "$new_pod" -n openshift-ovn-kubernetes -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
                if [[ "$pod_ready" == "True" ]]; then
                    echo "✅ New pod $new_pod is ready"
                    break
                fi
            fi
            sleep 10
            ready_wait=$((ready_wait + 10))
            echo "Waiting for pod readiness... (${ready_wait}s elapsed)"
        done
        
        if [[ -z "$new_pod" ]] || [[ $ready_wait -ge 300 ]]; then
            echo "❌ ERROR: Timeout waiting for new ovnkube-node pod"
            sync_results+=("$node_name:TIMEOUT")
            ((failed_syncs++))
            continue
        fi
        
        # Wait additional time for ovnkube-node to initialize and start service sync
        echo "Waiting 60 seconds for ovnkube-node initialization..."
        sleep 60
        
        # Extract service sync time from logs
        echo "Analyzing service sync logs for pod $new_pod..."
        local sync_start_time sync_end_time sync_duration
        
        # Get all gateway service sync logs
        local sync_logs
        sync_logs=$(oc logs -n openshift-ovn-kubernetes "$new_pod" -c ovnkube-controller --since-time="$restart_timestamp" | grep -i "gateway service sync" || echo "")
        
        if [[ -n "$sync_logs" ]]; then
            echo "Gateway service sync logs:"
            echo "$sync_logs"
            
            # Extract the most recent complete sync (start + done pair)
            sync_start_time=$(echo "$sync_logs" | grep "Starting gateway service sync" | tail -1 | awk '{print $1" "$2}' | sed 's/I//' || echo "")
            sync_end_time=$(echo "$sync_logs" | grep "Gateway service sync done" | tail -1 | awk '{print $1" "$2}' | sed 's/I//' || echo "")
            
            if [[ -n "$sync_start_time" ]] && [[ -n "$sync_end_time" ]]; then
                # Extract duration from the "Gateway service sync done" line
                sync_duration=$(echo "$sync_logs" | grep "Gateway service sync done" | tail -1 | grep -o "Time taken: [0-9.]*s" | grep -o "[0-9.]*" || echo "")
                
                if [[ -n "$sync_duration" ]]; then
                    echo "✅ Service sync completed in ${sync_duration}s"
                    sync_results+=("$node_name:$sync_duration")
                    
                    # Check if sync time is within threshold
                    if (( $(echo "$sync_duration > $SYNC_TIME_THRESHOLD" | python3 -c "import sys; print(1 if float(sys.stdin.read().strip().split()[-1]) > float('$SYNC_TIME_THRESHOLD') else 0)") )); then
                        echo "⚠️  WARNING: Sync time ${sync_duration}s exceeds threshold ${SYNC_TIME_THRESHOLD}s"
                        ((failed_syncs++))
                    else
                        echo "✅ Sync time ${sync_duration}s is within threshold"
                    fi
                else
                    echo "❌ ERROR: Could not extract sync duration"
                    sync_results+=("$node_name:PARSE_ERROR")
                    ((failed_syncs++))
                fi
            else
                echo "❌ ERROR: Could not find complete sync start/end times"
                sync_results+=("$node_name:INCOMPLETE")
                ((failed_syncs++))
            fi
        else
            echo "❌ ERROR: No gateway service sync logs found"
            sync_results+=("$node_name:NO_LOGS")
            ((failed_syncs++))
        fi
        
        # Save individual pod sync logs
        {
            echo "=== OVN Service Sync Test Results for $new_pod ==="
            echo "Node: $node_name"
            echo "Restart timestamp: $restart_timestamp"
            echo "Test timestamp: $(date)"
            echo ""
            echo "Gateway service sync logs:"
            echo "$sync_logs"
        } > "$RESULTS_DIR/sync-logs-$node_name-$test_count.txt"
        
        # Add delay between pod restarts to avoid overwhelming the system
        if [[ $i -lt $((pods_to_test - 1)) ]]; then
            echo "Waiting 30 seconds before next pod test..."
            sleep 30
        fi
    done
    
    # Generate comprehensive summary report
    echo ""
    echo "=== SERVICE SYNC PERFORMANCE SUMMARY ==="
    {
        echo "==========================================="
        echo "  OVN SERVICE SYNC PERFORMANCE RESULTS"
        echo "==========================================="
        echo ""
        echo "Test Configuration:"
        echo "  LoadBalancer services: $(oc get services -n $TEST_NAMESPACE --no-headers | wc -l)"
        echo "  Backend pods: $(oc get pods -n $TEST_NAMESPACE --no-headers | grep " Running" | wc -l)"
        echo "  Worker nodes tested: $test_count"
        echo "  Sync time threshold: ${SYNC_TIME_THRESHOLD}s"
        echo "  Test timestamp: $(date)"
        echo ""
        echo "Results:"
        
        local total_valid_syncs=0
        local total_sync_time=0
        local min_sync_time=999
        local max_sync_time=0
        
        for result in "${sync_results[@]}"; do
            local node
            local sync_time
            node=$(echo "$result" | cut -d':' -f1)
            sync_time=$(echo "$result" | cut -d':' -f2)
            echo "  $node: $sync_time"
            
            # Calculate statistics for valid numeric results
            if [[ "$sync_time" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                ((total_valid_syncs++))
                total_sync_time=$(echo "$total_sync_time + $sync_time" | python3 -c "import sys; print(eval(sys.stdin.read().strip()))")
                if (( $(python3 -c "import sys; print(1 if float('$sync_time') < float('$min_sync_time') else 0)") )); then
                    min_sync_time=$sync_time
                fi
                if (( $(python3 -c "import sys; print(1 if float('$sync_time') > float('$max_sync_time') else 0)") )); then
                    max_sync_time=$sync_time
                fi
            fi
        done
        
        echo ""
        echo "Summary:"
        echo "  Total pods tested: $test_count"
        echo "  Successful syncs: $total_valid_syncs"
        echo "  Failed syncs: $failed_syncs"
        
        if [[ $total_valid_syncs -gt 0 ]]; then
            local avg_sync_time
            avg_sync_time=$(python3 -c "print(f'{float('$total_sync_time') / float('$total_valid_syncs'):.2f}')")
            echo "  Average sync time: ${avg_sync_time}s"
            echo "  Min sync time: ${min_sync_time}s"
            echo "  Max sync time: ${max_sync_time}s"
        fi
        
        local success_rate=$((($test_count - failed_syncs) * 100 / test_count))
        echo "  Success rate: ${success_rate}%"
        echo ""
        
        if [[ $failed_syncs -eq 0 ]]; then
            echo "🎉 TEST PASSED: All ovnkube-node pods completed service sync within threshold"
        else
            echo "⚠️  TEST WARNING: $failed_syncs ovnkube-node pods had issues with service sync"
        fi
        
        echo ""
        echo "Artifacts saved to: $RESULTS_DIR/"
        echo "  - workload-summary.txt"
        echo "  - sync-logs-*.txt"
        echo "  - service-sync-summary.txt"
        echo "==========================================="
    } | tee "$RESULTS_DIR/service-sync-summary.txt"
    
    # Return exit code based on results
    if [[ $failed_syncs -gt 0 ]]; then
        echo ""
        echo "❌ Test completed with $failed_syncs failures"
        return 1
    else
        echo ""
        echo "✅ Test completed successfully - all service syncs within threshold"
        return 0
    fi
}

# Function to cleanup test resources
cleanup_test_workload() {
    echo ""
    echo "=== STEP 4: Cleanup test resources ==="
    if oc get namespace $TEST_NAMESPACE >/dev/null 2>&1; then
        echo "Cleaning up test namespace $TEST_NAMESPACE..."
        oc delete namespace $TEST_NAMESPACE --timeout=300s || {
            echo "⚠️  Warning: Cleanup timeout, but continuing..."
        }
    else
        echo "Test namespace $TEST_NAMESPACE does not exist, skipping cleanup"
    fi
}

# Main test execution
main() {
    echo "$(date): Starting OVN service sync performance test"
    
    # Step 1: Wait for expected worker nodes
    wait_for_workers
    
    # Step 2: Create test workload
    create_test_workload
    
    # Step 3: Test OVN service sync performance
    local test_result=0
    test_ovn_service_sync || test_result=$?
    
    # Step 4: Cleanup (always run)
    cleanup_test_workload
    
    if [[ $test_result -eq 0 ]]; then
        echo "$(date): OVN service sync performance test completed successfully"
    else
        echo "$(date): OVN service sync performance test completed with issues"
        exit $test_result
    fi
}

# Run main function
main