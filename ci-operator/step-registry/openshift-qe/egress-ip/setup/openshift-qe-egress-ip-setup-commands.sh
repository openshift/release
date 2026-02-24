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

# Egress IP configuration - supports multiple IPs for future scalability
EGRESS_IP_COUNT="${EGRESS_IP_COUNT:-1}"  # Default to 1 IP, configurable via environment variable
echo "Egress IP count configuration: $EGRESS_IP_COUNT IP(s) will be allocated"

# Get worker nodes for egress IP assignment (using cloud-bulldozer kube-burner pattern)
# Use the same node selection criteria as cloud-bulldozer egressip workload
mapfile -t WORKER_NODES < <(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
WORKER_NODE="${WORKER_NODES[0]}"
echo "Cloud-bulldozer pattern: Selected worker node: $WORKER_NODE (from ${#WORKER_NODES[@]} available workers)"

# For chaos testing compatibility, save all worker nodes for chaos scenarios
if [[ ${#WORKER_NODES[@]} -gt 1 ]]; then
    echo "Additional worker nodes available for chaos testing: $((${#WORKER_NODES[@]} - 1))"
    # Save all worker nodes for chaos scenarios
    printf '%s\n' "${WORKER_NODES[@]}" > "$SHARED_DIR/worker-nodes"
fi

# Create test namespace with proper labels for kube-burner compatibility
TEST_NAMESPACE=${TEST_NAMESPACE:-"egress-ip-test"}
echo "Creating test namespace: $TEST_NAMESPACE"
oc create namespace "$TEST_NAMESPACE" || true
oc label namespace "$TEST_NAMESPACE" egress-ip=enabled --overwrite

if [[ $RUNNING_CNI == "OVNKubernetes" ]]; then
    echo "Configuring OVNKubernetes egress IP"
    
    # Label the node as egress assignable
    oc label node --overwrite "$WORKER_NODE" k8s.ovn.org/egress-assignable=
    
    # Extract egress IP range from node annotations
    # Use a simple approach: try to get the subnet and assign an IP from it
    # If annotation exists, parse it; otherwise use a default approach
    egress_config=$(oc get node "$WORKER_NODE" -o jsonpath="{.metadata.annotations.cloud\.network\.openshift\.io/egress-ipconfig}" 2>/dev/null || echo "")
    
    # Function to find available egress IPs in subnet (supports multiple IPs)
    # Usage: find_available_egress_ip <base_ip> [count]
    # Returns: Space-separated list of available IPs
    find_available_egress_ip() {
        local base_ip="$1"
        local ip_count="${2:-1}"  # Default to 1 IP if count not specified
        local subnet_prefix="${base_ip%.*}"
        local found_ips=()
        
        # Validate input
        if [[ $ip_count -lt 1 || $ip_count -gt 50 ]]; then
            echo "❌ ERROR: Invalid IP count: $ip_count (must be 1-50)" >&2
            return 1
        fi
        
        # Get all existing node IPs to avoid conflicts
        local existing_ips
        mapfile -t existing_ips < <(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n')
        
        # Get all existing egress IPs to avoid conflicts
        local existing_egress_ips
        mapfile -t existing_egress_ips < <(oc get egressip -o jsonpath='{.items[*].spec.egressIPs[*]}' 2>/dev/null | tr ' ' '\n')
        
        echo "🔍 Searching for $ip_count available egress IP(s) in subnet $subnet_prefix.0/24..." >&2
        echo "Existing node IPs: ${existing_ips[*]}" >&2
        echo "Existing egress IPs: ${existing_egress_ips[*]}" >&2
        
        # Try IP addresses from .200 to .254 (high range to avoid typical node assignments)
        for ip_suffix in {200..254}; do
            candidate_ip="$subnet_prefix.$ip_suffix"
            
            # Check if IP conflicts with existing node IPs
            local ip_conflict=false
            for existing_ip in "${existing_ips[@]}"; do
                if [[ "$candidate_ip" == "$existing_ip" ]]; then
                    echo "❌ IP conflict: $candidate_ip already used by node" >&2
                    ip_conflict=true
                    break
                fi
            done
            
            # Check if IP conflicts with existing egress IPs
            if [[ "$ip_conflict" == false ]]; then
                for existing_egress_ip in "${existing_egress_ips[@]}"; do
                    if [[ "$candidate_ip" == "$existing_egress_ip" ]]; then
                        echo "❌ IP conflict: $candidate_ip already used by egress IP" >&2
                        ip_conflict=true
                        break
                    fi
                done
            fi
            
            # Check if IP conflicts with already found IPs in this session
            if [[ "$ip_conflict" == false ]]; then
                for found_ip in "${found_ips[@]}"; do
                    if [[ "$candidate_ip" == "$found_ip" ]]; then
                        ip_conflict=true
                        break
                    fi
                done
            fi
            
            # Test IP availability with ping (optional - basic check)
            if [[ "$ip_conflict" == false ]]; then
                # Quick ping test from worker node (if possible)
                if oc debug node/"$WORKER_NODE" -- ping -c 1 -W 2 "$candidate_ip" >/dev/null 2>&1; then
                    echo "❌ IP conflict: $candidate_ip responds to ping" >&2
                    ip_conflict=true
                fi
            fi
            
            if [[ "$ip_conflict" == false ]]; then
                found_ips+=("$candidate_ip")
                echo "✅ Found available egress IP: $candidate_ip (${#found_ips[@]}/$ip_count)" >&2
                
                # Check if we have found enough IPs
                if [[ ${#found_ips[@]} -eq $ip_count ]]; then
                    echo "✅ Successfully found $ip_count available egress IP(s): ${found_ips[*]}" >&2
                    echo "${found_ips[*]}"  # Return space-separated list
                    return 0
                fi
            fi
        done
        
        if [[ ${#found_ips[@]} -eq 0 ]]; then
            echo "❌ ERROR: No available IPs found in subnet $subnet_prefix.0/24" >&2
            return 1
        else
            echo "❌ ERROR: Only found ${#found_ips[@]} available IPs, but $ip_count requested" >&2
            echo "Available IPs found: ${found_ips[*]}" >&2
            return 1
        fi
    }

    if [[ -n "$egress_config" && "$egress_config" != "null" ]]; then
        # Parse the JSON manually to extract ipv4 CIDR
        # Look for "ipv4":"x.x.x.x/xx" pattern
        egress_cidrs=$(echo "$egress_config" | sed -n 's/.*"ipv4":"\([^"]*\)".*/\1/p' | head -n1)
        if [[ -n "$egress_cidrs" ]]; then
            ip_part=$(echo "$egress_cidrs" | cut -d'/' -f1)
            # Find available IPs with flexible count support
            egress_ips=$(find_available_egress_ip "$ip_part" "$EGRESS_IP_COUNT")
            if [[ -z "$egress_ips" ]]; then
                echo "ERROR: Cannot find $EGRESS_IP_COUNT available egress IP(s) in configured subnet"
                exit 1
            fi
            # For backwards compatibility, use first IP for single IP scenarios
            egress_ip=$(echo "$egress_ips" | cut -d' ' -f1)
        else
            # Fallback: extract node IP and use same subnet
            node_ip=$(oc get node "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
            # Find available IPs with flexible count support
            egress_ips=$(find_available_egress_ip "$node_ip" "$EGRESS_IP_COUNT")
            if [[ -z "$egress_ips" ]]; then
                echo "ERROR: Cannot find $EGRESS_IP_COUNT available egress IP(s) in node subnet"
                exit 1
            fi
            # For backwards compatibility, use first IP for single IP scenarios
            egress_ip=$(echo "$egress_ips" | cut -d' ' -f1)
            egress_cidrs="${node_ip}/24"
        fi
    else
        # Fallback: extract node IP and use same subnet
        node_ip=$(oc get node "$WORKER_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        # Find available IPs with flexible count support
        egress_ips=$(find_available_egress_ip "$node_ip" "$EGRESS_IP_COUNT")
        if [[ -z "$egress_ips" ]]; then
            echo "ERROR: Cannot find $EGRESS_IP_COUNT available egress IP(s) in node subnet"
            exit 1
        fi
        # For backwards compatibility, use first IP for single IP scenarios
        egress_ip=$(echo "$egress_ips" | cut -d' ' -f1)
        egress_cidrs="${node_ip}/24"
    fi
    
    echo "Egress IP CIDR: $egress_cidrs"
    if [[ $EGRESS_IP_COUNT -eq 1 ]]; then
        echo "Selected egress IP candidate: $egress_ip"
    else
        echo "Selected egress IP candidates ($EGRESS_IP_COUNT): $egress_ips"
        echo "Primary egress IP (for current test): $egress_ip"
    fi
    
    # Create EgressIP custom resource using cloud-bulldozer proven methodology
    # Scale based on worker count like cloud-bulldozer's kube-burner workload
    echo "Creating EgressIP resource using cloud-bulldozer scaling approach (workers: $CURRENT_WORKER_COUNT)"
    
    # Generate dynamic EgressIP resource with flexible IP count support
    EGRESS_IP_YAML=$(cat <<EOF
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egress-ip-test
  labels:
    app: kube-burner
    workload: egressip
    chaos-engineering: "true"
    ip-count: "$EGRESS_IP_COUNT"
spec:
  egressIPs:
EOF
)
    
    # Add all allocated IPs to the EgressIP resource
    for ip in $egress_ips; do
        EGRESS_IP_YAML+=$'\n'"  - \"$ip\""
    done
    
    # Complete the EgressIP resource
    EGRESS_IP_YAML+=$(cat <<EOF

  namespaceSelector:
    matchLabels:
      egress-ip: enabled
  # Cloud-bulldozer compatible configuration
  nodeSelector:
    matchLabels:
      k8s.ovn.org/egress-assignable: ""
EOF
)
    
    echo "$EGRESS_IP_YAML" | oc apply -f -

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
    
    # DEBUG: Comprehensive EgressIP configuration verification
    echo "🔍 DEBUG: EgressIP Configuration Details:"
    echo "----------------------------------------"
    oc get egressip egress-ip-test -o yaml || true
    echo ""
    echo "🔍 DEBUG: Namespace labels verification:"
    oc get namespace $TEST_NAMESPACE --show-labels || true
    echo ""
    echo "🔍 DEBUG: Node egress-assignable labels:"
    oc get nodes --show-labels | grep egress-assignable || true
    echo ""
    echo "🔍 DEBUG: EgressIP resource status:"
    oc describe egressip egress-ip-test || true
    echo "----------------------------------------"
    
    # Save configuration for validation steps (cloud-bulldozer + chaos testing compatible)
    echo "$egress_ip" > "$SHARED_DIR/egress-ip"  # Primary IP (backwards compatibility)
    echo "$egress_ips" > "$SHARED_DIR/egress-ips"  # All IPs (multi-IP support)
    echo "$EGRESS_IP_COUNT" > "$SHARED_DIR/egress-ip-count"  # IP count
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
EGRESS_IPS="$egress_ips"
EGRESS_IP_COUNT=$EGRESS_IP_COUNT
EGRESS_NODE=$assigned_node
EGRESS_NAMESPACE=$TEST_NAMESPACE
PPROF=false
CHURN=false
ES_SERVER=""
CONFIG_EOF
    
    # Use external bastion agnhost service for proper egress IP validation
    echo "Setting up external bastion agnhost service for egress IP validation..."
    echo "Using bastion-hosted agnhost service to validate egress IP with $CURRENT_WORKER_COUNT worker scaling"
    
    # Check if bastion agnhost service is available
    if [[ -f "$SHARED_DIR/egress-bastion-echo-url" ]]; then
        EXTERNAL_IPECHO_URL=$(cat "$SHARED_DIR/egress-bastion-echo-url")
        echo "✅ Using bastion-hosted agnhost service: $EXTERNAL_IPECHO_URL"
    else
        echo "⚠️ Bastion agnhost service not found, falling back to httpbin.org"
        EXTERNAL_IPECHO_URL="https://httpbin.org/ip"
    fi
    
    # Store the external service URL for health check validation
    echo "$EXTERNAL_IPECHO_URL" > "$SHARED_DIR/health-check-url"
    echo "External agnhost service configured: $EXTERNAL_IPECHO_URL"
    
    # Skip AWS NAT IP testing - not relevant for egress IP validation
    echo "ℹ️  Skipping external NAT IP baseline - focusing on internal egress IP validation"
    
    # Verify external agnhost service is accessible
    echo "Verifying external agnhost service accessibility..."
    # Create a test pod to verify connectivity
    cat << EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: agnhost-connectivity-test
  namespace: $TEST_NAMESPACE
spec:
  # IMPORTANT: Pod intentionally scheduled randomly across cluster nodes
  # This tests realistic scenario where egress IP pods can be anywhere  
  # Egress IP routing works from any node - not just the egress IP assigned node
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
    if oc wait --for=condition=Ready pod/agnhost-connectivity-test -n "$TEST_NAMESPACE" --timeout=60s; then
        echo "Testing connectivity to external agnhost service..."
        # agnhost /clientip endpoint returns plain text source IP
        test_response=$(oc exec -n "$TEST_NAMESPACE" agnhost-connectivity-test -- timeout 10 curl -s "$EXTERNAL_IPECHO_URL" 2>/dev/null || echo "")
        if [[ -n "$test_response" && "$test_response" != *"error"* ]]; then
            echo "✅ External agnhost service is accessible"
            echo "Sample response: $test_response"
        else
            echo "⚠️ Warning: External agnhost service test failed, but continuing..."
        fi
    else
        echo "⚠️ Warning: Test pod not ready, but continuing with external service..."
    fi
    
    # Cleanup test pod
    oc delete pod agnhost-connectivity-test -n "$TEST_NAMESPACE" --ignore-not-found=true
    
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
        oc label namespace "$TRAFFIC_NAMESPACE" egress-ip=enabled --overwrite
        
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
  # IMPORTANT: Pods intentionally scheduled randomly across cluster nodes
  # This tests realistic scenario where egress IP workloads are distributed
  # Egress IP routing works from any node - not just the egress IP assigned node
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
        # HTTP traffic to external agnhost service (egress1.sh pattern)
        # agnhost /clientip endpoint returns plain text source IP
        # Note: Traffic generation for realistic load - actual validation happens in test scripts
        curl -s "$EXTERNAL_IPECHO_URL" >/dev/null 2>&1 || true
        
        # High frequency ping tests (ovn-pod-stress-test.sh pattern)
        # Note: Network stress testing - actual validation happens in test scripts  
        ping -c 10 -i 0.1 8.8.8.8 >/dev/null 2>&1 || true
        
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
