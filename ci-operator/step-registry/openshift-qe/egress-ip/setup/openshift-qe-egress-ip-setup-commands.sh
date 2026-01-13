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
WORKER_NODES=($(oc get nodes --no-headers -l node-role.kubernetes.io/worker=,node-role.kubernetes.io/infra!=,node-role.kubernetes.io/workload!= -o jsonpath='{.items[*].metadata.name}'))
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
    
    # Deploy ipecho service on external jump host for proper egress IP validation
    echo "Deploying ipecho service using cloud-bulldozer compatible external validation methodology..."
    
    # Jump host configuration (cloud-bulldozer compatible setup)
    JUMP_HOST="3.15.195.250"
    JUMP_USER="fedora"
    SSH_KEY="$SHARED_DIR/lqclk.pem"
    IPECHO_PORT="8080"
    
    echo "Using cloud-bulldozer external validation approach with $CURRENT_WORKER_COUNT worker scaling"
    
    # Copy SSH key if available (assuming it's in cluster profile or shared dir)
    if [[ -f "$CLUSTER_PROFILE_DIR/ssh-privatekey" ]]; then
        cp "$CLUSTER_PROFILE_DIR/ssh-privatekey" "$SSH_KEY"
        chmod 600 "$SSH_KEY"
    elif [[ -f "$CLUSTER_PROFILE_DIR/lqclk.pem" ]]; then
        cp "$CLUSTER_PROFILE_DIR/lqclk.pem" "$SSH_KEY"
        chmod 600 "$SSH_KEY"
    else
        echo "Warning: SSH key not found in cluster profile, using default SSH method"
        SSH_KEY=""
    fi
    
    # Deploy ipecho on jump host
    if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
        SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    else
        SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    fi
    
    # Deploy ipecho container on jump host
    $SSH_CMD "$JUMP_USER@$JUMP_HOST" << 'JUMP_EOF'
        # Become root
        sudo su - << 'ROOT_EOF'
            # Stop any existing ipecho containers
            podman stop ipecho-service 2>/dev/null || true
            podman rm ipecho-service 2>/dev/null || true
            
            # Pull and run ipecho container
            podman pull quay.io/openshifttest/ip-echo:1.2.0
            podman run -d --name ipecho-service \
                -p 8080:8080 \
                quay.io/openshifttest/ip-echo:1.2.0 \
                /ip-echo --listen=0.0.0.0:8080
            
            # Wait for container to start
            sleep 5
            
            # Verify service is running
            podman ps | grep ipecho-service
            curl -s http://localhost:8080 || echo "ipecho service starting..."
            
            echo "External ipecho service deployed successfully on port 8080"
ROOT_EOF
JUMP_EOF
    
    # Create health check URL for krkn chaos testing using external ipecho service
    echo "http://$JUMP_HOST:$IPECHO_PORT" > "$SHARED_DIR/egress-health-check-url"
    echo "Created external egress IP health check URL: http://$JUMP_HOST:$IPECHO_PORT"
    
    # Save jump host info for cleanup
    echo "$JUMP_HOST" > "$SHARED_DIR/jump-host"
    echo "$JUMP_USER" > "$SHARED_DIR/jump-user"
    
elif [[ $RUNNING_CNI == "OpenShiftSDN" ]]; then
    echo "OpenShiftSDN configuration not implemented in this version"
    echo "This test focuses on OVNKubernetes clusters"
    exit 1
else
    echo "Unsupported CNI type: $RUNNING_CNI"
    exit 1
fi

echo "Egress IP setup completed successfully"
