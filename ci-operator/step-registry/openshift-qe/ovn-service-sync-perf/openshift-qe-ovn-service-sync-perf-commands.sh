#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Environment variables with defaults
export EXPECTED_WORKER_NODES="${EXPECTED_WORKER_NODES:-5}"
export LOADBALANCER_SERVICES="${LOADBALANCER_SERVICES:-500}"
export BACKEND_PODS="${BACKEND_PODS:-1000}"
export SYNC_TIME_THRESHOLD="${SYNC_TIME_THRESHOLD:-10}"  # seconds
export TEST_TIMEOUT="${TEST_TIMEOUT:-30m}"

echo "=== OVN Service Sync Performance Test ==="
echo "Target configuration:"
echo "  Workers: $EXPECTED_WORKER_NODES"
echo "  LoadBalancer services: $LOADBALANCER_SERVICES"
echo "  Backend pods: $BACKEND_PODS"
echo "  Sync time threshold: ${SYNC_TIME_THRESHOLD}s"

# Create results directory
RESULTS_DIR="${ARTIFACT_DIR:-/tmp}/ovn-service-sync-results"
mkdir -p "$RESULTS_DIR"

# Function to check if cluster has expected number of worker nodes
wait_for_workers() {
    echo "Waiting for $EXPECTED_WORKER_NODES worker nodes to be ready..."
    local timeout=600  # 10 minutes
    local start_time=$(date +%s)
    
    while true; do
        local ready_workers=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker | grep " Ready" | wc -l)
        echo "Ready workers: $ready_workers/$EXPECTED_WORKER_NODES"
        
        if [[ $ready_workers -ge $EXPECTED_WORKER_NODES ]]; then
            echo "✅ All $EXPECTED_WORKER_NODES worker nodes are ready"
            return 0
        fi
        
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [[ $elapsed -gt $timeout ]]; then
            echo "❌ Timeout waiting for worker nodes"
            oc get nodes
            return 1
        fi
        
        sleep 30
    done
}

# Function to create LoadBalancer services and backend pods
create_test_workload() {
    echo "Creating test namespace..."
    oc create namespace ovn-sync-test || true
    oc project ovn-sync-test
    
    echo "Creating $LOADBALANCER_SERVICES LoadBalancer services with $BACKEND_PODS backend pods..."
    
    # Create deployment template for backend pods
    cat > "$RESULTS_DIR/backend-deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-pods
  namespace: ovn-sync-test
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
    oc wait --for=condition=available --timeout=10m deployment/backend-pods -n ovn-sync-test
    
    # Create LoadBalancer services
    echo "Creating LoadBalancer services..."
    for i in $(seq 1 $LOADBALANCER_SERVICES); do
        cat > "$RESULTS_DIR/service-${i}.yaml" << EOF
apiVersion: v1
kind: Service
metadata:
  name: lb-service-${i}
  namespace: ovn-sync-test
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
            echo "Created $i/$LOADBALANCER_SERVICES services..."
        fi
    done
    
    echo "✅ Created $LOADBALANCER_SERVICES LoadBalancer services"
    echo "✅ Backend pods: $(oc get pods -l app=backend --no-headers | wc -l)/$BACKEND_PODS"
}

# Function to restart ovnkube-node pods and measure sync times
test_ovn_service_sync() {
    echo "=== Testing OVN Service Sync Performance ==="
    
    # Get all ovnkube-node pods
    local ovnkube_pods
    mapfile -t ovnkube_pods < <(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --no-headers -o custom-columns=NAME:.metadata.name)
    
    echo "Found ${#ovnkube_pods[@]} ovnkube-node pods: ${ovnkube_pods[*]}"
    
    # Test results storage
    local sync_results=()
    local failed_syncs=0
    
    for pod in "${ovnkube_pods[@]}"; do
        echo "Testing service sync for pod: $pod"
        
        # Get pod node for identification
        local node_name
        node_name=$(oc get pod "$pod" -n openshift-ovn-kubernetes -o jsonpath='{.spec.nodeName}')
        
        # Restart the ovnkube-node pod
        echo "Restarting ovnkube-node pod $pod on node $node_name"
        oc delete pod "$pod" -n openshift-ovn-kubernetes
        
        # Wait for pod to be ready again
        echo "Waiting for ovnkube-node pod to restart..."
        oc wait --for=condition=ready --timeout=5m pod -l app=ovnkube-node -n openshift-ovn-kubernetes --field-selector spec.nodeName="$node_name"
        
        # Get the new pod name
        local new_pod
        new_pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName="$node_name" --no-headers -o custom-columns=NAME:.metadata.name)
        
        # Wait a bit for logs to accumulate
        sleep 10
        
        # Extract service sync time from logs
        echo "Analyzing service sync logs for pod $new_pod..."
        local sync_logs
        sync_logs=$(oc logs -n openshift-ovn-kubernetes "$new_pod" -c ovnkube-controller --tail=50 | grep -i "gateway service sync done" | tail -1 || echo "")
        
        if [[ -n "$sync_logs" ]]; then
            # Extract time from log line like: "Gateway service sync done. Time taken: 3.994499442s"
            local sync_time
            sync_time=$(echo "$sync_logs" | grep -o "Time taken: [0-9.]*s" | grep -o "[0-9.]*" || echo "0")
            
            echo "Node $node_name: Service sync time = ${sync_time}s"
            sync_results+=("$node_name:$sync_time")
            
            # Check if sync time is within threshold
            if (( $(echo "$sync_time > $SYNC_TIME_THRESHOLD" | bc -l) )); then
                echo "⚠️  WARNING: Sync time ${sync_time}s exceeds threshold ${SYNC_TIME_THRESHOLD}s"
                ((failed_syncs++))
            else
                echo "✅ Sync time ${sync_time}s is within threshold"
            fi
        else
            echo "❌ ERROR: Could not find service sync logs for pod $new_pod"
            sync_results+=("$node_name:FAILED")
            ((failed_syncs++))
        fi
        
        # Add delay between pod restarts
        sleep 30
    done
    
    # Generate summary report
    echo "=== Service Sync Performance Summary ==="
    {
        echo "Test Configuration:"
        echo "  Worker nodes: $EXPECTED_WORKER_NODES"
        echo "  LoadBalancer services: $LOADBALANCER_SERVICES"
        echo "  Backend pods: $BACKEND_PODS"
        echo "  Sync time threshold: ${SYNC_TIME_THRESHOLD}s"
        echo ""
        echo "Results:"
        for result in "${sync_results[@]}"; do
            echo "  $result"
        done
        echo ""
        echo "Summary:"
        echo "  Total ovnkube-node pods tested: ${#ovnkube_pods[@]}"
        echo "  Failed syncs (exceeded threshold): $failed_syncs"
        echo "  Success rate: $(( (${#ovnkube_pods[@]} - failed_syncs) * 100 / ${#ovnkube_pods[@]} ))%"
    } | tee "$RESULTS_DIR/sync-performance-summary.txt"
    
    # Exit with error if any syncs failed
    if [[ $failed_syncs -gt 0 ]]; then
        echo "❌ Test FAILED: $failed_syncs ovnkube-node pods had service sync times exceeding ${SYNC_TIME_THRESHOLD}s threshold"
        return 1
    else
        echo "✅ Test PASSED: All ovnkube-node pods completed service sync within ${SYNC_TIME_THRESHOLD}s threshold"
        return 0
    fi
}

# Function to cleanup test resources
cleanup_test_workload() {
    echo "Cleaning up test resources..."
    oc delete namespace ovn-sync-test --timeout=300s || true
}

# Main test execution
main() {
    echo "$(date): Starting OVN service sync performance test"
    
    # Step 1: Wait for expected worker nodes
    wait_for_workers
    
    # Step 2: Create test workload
    create_test_workload
    
    # Step 3: Test OVN service sync performance
    test_ovn_service_sync
    
    # Step 4: Cleanup (always run)
    cleanup_test_workload
    
    echo "$(date): OVN service sync performance test completed successfully"
}

# Run main function
main