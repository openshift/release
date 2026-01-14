#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Setting up egress IP configuration using cloud-bulldozer kube-burner methodology"
echo "Combined with OpenShift QE chaos engineering validation framework"

# Detect the CNI type
RUNNING_CNI=$(oc get network.operator cluster -o=jsonpath='{.spec.defaultNetwork.type}')
echo "Detected CNI: $RUNNING_CNI"

# Use cloud-bulldozer methodology for worker node count scaling
CURRENT_WORKER_COUNT=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)
echo "Cloud-bulldozer methodology: Detected $CURRENT_WORKER_COUNT ready worker nodes"

# Get worker nodes for egress IP assignment (using cloud-bulldozer kube-burner pattern)
# Use the same node selection criteria as cloud-bulldozer egressip workload
mapfile -t WORKER_NODES < <(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
WORKER_NODE="${WORKER_NODES[0]}"
echo "Cloud-bulldozer pattern: Selected worker node: $WORKER_NODE (from ${#WORKER_NODES[@]} available workers)"

# For chaos testing compatibility, also prepare additional worker nodes
if [[ ${#WORKER_NODES[@]} -gt 1 ]]; then
    SECONDARY_WORKER="${WORKER_NODES[1]}"
    echo "Secondary worker node for chaos testing: $SECONDARY_WORKER"
    # Save all worker nodes for chaos scenarios
    printf '%s\n' "${WORKER_NODES[@]}" > "$SHARED_DIR/worker-nodes"
fi

# Create test namespace with proper labels for kube-burner compatibility
TEST_NAMESPACE=${TEST_NAMESPACE:-"egress-ip-test"}
echo "Creating test namespace: $TEST_NAMESPACE"
oc create namespace "$TEST_NAMESPACE" || true

if [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
    echo "Configuring OVNKubernetes egress IP"
    
    # Label the node as egress assignable
    oc label node --overwrite "$WORKER_NODE" k8s.ovn.org/egress-assignable=
    
    # Extract egress IP range from node annotations
    # Use a simple approach: try to get the subnet and assign an IP from it
    # If annotation exists, parse it; otherwise use a default approach
    egress_config=$(oc get node "$WORKER_NODE" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" 2>/dev/null || echo "")
    
    if [[ -n "$egress_config" && "$egress_config" != "null" ]]; then
        # Parse the JSON manually to extract ipv4 CIDR
        # Look for "ipv4":"x.x.x.x/xx" pattern
        egress_cidrs=$(echo "$egress_config" | sed -n 's/.*"ipv4":"\([^"]*\)".*/\1/p' | head -n1)
        if [[ -n "$egress_cidrs" ]]; then
            ip_part=$(echo "$egress_cidrs" | cut -d'/' -f1)
            egress_ip="${ip_part%.*}.10"  # Use .10 instead of .5 to avoid conflicts
        else
            # Fallback: extract node IP and use same subnet
            node_ip=$(oc get node "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
            egress_ip="${node_ip%.*}.10"
            egress_cidrs="${node_ip}/24"
        fi
    else
        # Fallback: extract node IP and use same subnet
        node_ip=$(oc get node "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        egress_ip="${node_ip%.*}.10"
        egress_cidrs="${node_ip}/24"
    fi
    
    echo "Egress IP CIDR: $egress_cidrs"
    echo "Assigned egress IP: $egress_ip"
    
    # Create EgressIP custom resource using cloud-bulldozer proven methodology
    # Scale based on worker count like cloud-bulldozer's kube-burner workload
    echo "Creating EgressIP resource using cloud-bulldozer scaling approach (workers: $CURRENT_WORKER_COUNT)"
    
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egress-ip-test
  labels:
    app: kube-burner
    workload: egressip
    chaos-engineering: "true"
spec:
  egressIPs:
  - "${egress_ip}"
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: "${TEST_NAMESPACE}"
  # Cloud-bulldozer compatible configuration
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF

    # Wait for EgressIP to be assigned
    echo "Waiting for EgressIP assignment..."
    for i in {1..60}; do
        status=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
        if [[ -n "$status" ]]; then
            echo "EgressIP successfully assigned to node: $status"
            break
        fi
        echo "Waiting for EgressIP assignment... (attempt $i/60)"
        sleep 5
    done
    
    # Verify assignment
    assigned_node=$(oc get egressip egress-ip-test -o jsonpath='{.status.items[*].node}' 2>/dev/null || echo "")
    if [[ -z "$assigned_node" ]]; then
        echo "ERROR: EgressIP failed to assign to any node"
        oc get egressip egress-ip-test -o yaml
        exit 1
    fi
    
    echo "EgressIP configuration completed successfully"
    echo "Egress IP: $egress_ip assigned to node: $assigned_node"
    
    # Save configuration for validation steps (cloud-bulldozer + chaos testing compatible)
    echo "$egress_ip" > "$SHARED_DIR/egress-ip"
    echo "$assigned_node" > "$SHARED_DIR/egress-node"
    echo "$TEST_NAMESPACE" > "$SHARED_DIR/egress-namespace"
    echo "$CURRENT_WORKER_COUNT" > "$SHARED_DIR/worker-count"
    
    # Save cloud-bulldozer methodology configuration for chaos scenarios
    cat > "$SHARED_DIR/cloud-bulldozer-config" << CONFIG_EOF
# Cloud-bulldozer kube-burner egressip workload configuration
WORKLOAD=egressip
ITERATIONS=$CURRENT_WORKER_COUNT
WORKER_COUNT=$CURRENT_WORKER_COUNT
EGRESS_IP=$egress_ip
EGRESS_NODE=$assigned_node
EGRESS_NAMESPACE=$TEST_NAMESPACE
PPROF=false
CHURN=false
ES_SERVER=""
CONFIG_EOF
    
    # Use external ipecho service for proper egress IP validation
    echo "Setting up external ipecho service for cloud-bulldozer compatible validation..."
    echo "Cloud-bulldozer methodology: Using external ipecho service to validate egress IP with $CURRENT_WORKER_COUNT worker scaling"
    
    # Use a well-known external IP echo service
    # This is similar to cloud-bulldozer's approach of testing against external services
    EXTERNAL_IPECHO_URL="https://httpbin.org/ip"
    
    # Store the expected egress IP for health check validation
    # The chaos framework will check if httpbin.org/ip is reachable
    # Our test scripts will validate the actual content/functionality
    echo "$EXTERNAL_IPECHO_URL" > "$SHARED_DIR/egress-health-check-url"
    echo "Using external IP echo service: $EXTERNAL_IPECHO_URL"
    
    # Store the expected external IP (AWS NAT public IP) for validation
    # This helps validate that egress IP pods reach external services consistently
    echo "Determining baseline external IP for health monitoring..."
    
    # Create a simple job instead of interactive pod
    cat << 'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: baseline-ip-check
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: registry.redhat.io/ubi9/ubi:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          # Install curl if not available
          curl --version >/dev/null 2>&1 || (echo "curl not found, trying to install..." && microdnf install -y curl)
          # Get external IP
          curl -s --max-time 15 https://httpbin.org/ip | grep -o '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "FAILED"
EOF

    # Wait for job completion
    if oc wait --for=condition=complete job/baseline-ip-check --timeout=90s >/dev/null 2>&1; then
        EXPECTED_EXTERNAL_IP=$(oc logs job/baseline-ip-check 2>/dev/null | tail -n1 | tr -d '\r\n')
        if [[ -n "$EXPECTED_EXTERNAL_IP" && "$EXPECTED_EXTERNAL_IP" != "FAILED" && "$EXPECTED_EXTERNAL_IP" != "null" ]]; then
            echo "$EXPECTED_EXTERNAL_IP" > "$SHARED_DIR/expected-external-ip"
            echo "Baseline external IP for health monitoring: $EXPECTED_EXTERNAL_IP"
        else
            echo "Warning: Could not determine baseline external IP - got: '$EXPECTED_EXTERNAL_IP'"
        fi
    else
        echo "Warning: Baseline IP detection job timed out"
    fi
    
    # Cleanup
    oc delete job baseline-ip-check >/dev/null 2>&1 || true
    
    # Verify external service is accessible
    echo "Verifying external ipecho service accessibility..."
    # Create a test pod to verify connectivity
    cat << EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ipecho-connectivity-test
  namespace: $TEST_NAMESPACE
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: test
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
  restartPolicy: Never
EOF

    # Wait for test pod and verify connectivity
    if oc wait --for=condition=Ready pod/ipecho-connectivity-test -n "$TEST_NAMESPACE" --timeout=60s; then
        echo "Testing connectivity to external ipecho service..."
        test_response=$(oc exec -n "$TEST_NAMESPACE" ipecho-connectivity-test -- timeout 10 curl -s "$EXTERNAL_IPECHO_URL" 2>/dev/null || echo "")
        if [[ -n "$test_response" ]]; then
            echo "✅ External ipecho service is accessible"
            echo "Sample response: $test_response"
        else
            echo "⚠️ Warning: External ipecho service test failed, but continuing..."
        fi
    else
        echo "⚠️ Warning: Test pod not ready, but continuing with external service..."
    fi
    
    # Cleanup test pod
    oc delete pod ipecho-connectivity-test -n "$TEST_NAMESPACE" --ignore-not-found=true
    
    # Deploy cloud-bulldozer style traffic generators and test projects
    echo "Deploying cloud-bulldozer traffic generators for egress IP testing..."
    echo "Creating multiple namespaces with traffic generation pods (cloud-bulldozer egress1.sh pattern)..."
    
    # Cloud-bulldozer creates multiple projects with pods generating traffic
    # Simulate their egress1.sh and egress_4p.sh approach
    NUM_PROJECTS=5  # Scaled down from cloud-bulldozer's 200 for CI efficiency
    
    for project_num in $(seq 1 "$NUM_PROJECTS"); do
        TRAFFIC_NAMESPACE="egress-test-project-$project_num"
        
        # Create namespace for this traffic generation project
        oc create namespace "$TRAFFIC_NAMESPACE" || true
        
        # Label the traffic namespace to use egress IP (cloud-bulldozer pattern)
        oc label namespace "$TRAFFIC_NAMESPACE" kubernetes.io/metadata.name="$TEST_NAMESPACE" --overwrite
        
        echo "Creating traffic generators in project $project_num/$NUM_PROJECTS..."
        
        # Deploy traffic generator pods (similar to cloud-bulldozer's curl-based approach)
        for pod_num in $(seq 1 2); do  # 2 pods per project for traffic generation
            cat << TRAFFIC_EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: traffic-gen-$pod_num
  namespace: $TRAFFIC_NAMESPACE
  labels:
    app: egress-traffic-gen
    workload: egressip
    cloud-bulldozer: "true"
    project: "project-$project_num"
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: traffic-generator
    image: quay.io/openshift/origin-network-tools:latest
    command: ["/bin/bash"]
    args:
    - "-c"
    - |
      # Cloud-bulldozer style continuous traffic generation
      echo "Starting cloud-bulldozer style traffic generation..."
      while true; do
        # HTTP traffic to external ipecho service (egress1.sh pattern)
        curl -s "$EXTERNAL_IPECHO_URL" > /tmp/egress_response.log 2>&1 || true
        echo "Traffic generated at \$(date)" >> /tmp/traffic.log
        
        # High frequency ping tests (ovn-pod-stress-test.sh pattern)  
        ping -c 10 -i 0.1 8.8.8.8 > /tmp/ping.log 2>&1 || true
        
        # Brief pause between traffic bursts
        sleep 30
      done
    env:
    - name: EXTERNAL_IPECHO_URL
      value: "$EXTERNAL_IPECHO_URL"
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
  restartPolicy: Never
TRAFFIC_EOF
        done
    done
    
    # Wait for some traffic generator pods to be ready
    echo "Waiting for traffic generator pods to start..."
    sleep 10  # Give pods time to start
    
    echo "Cloud-bulldozer traffic generators deployed successfully"
    echo "Traffic generation: $NUM_PROJECTS projects with continuous curl and ping traffic"
    echo "Pattern: Similar to cloud-bulldozer's egress1.sh, egress_4p.sh, and ovn-pod-stress-test.sh"
    
elif [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
    echo "OpenShiftSDN configuration not implemented in this version"
    echo "This test focuses on OVNKubernetes clusters"
    exit 1
else
    echo "Unsupported CNI type: $RUNNING_CNI"
    exit 1
fi

echo "Egress IP setup completed successfully"
