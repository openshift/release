#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# OpenShift QE Egress IP Scale Setup
# Configures scaled egress IP infrastructure for 10-node chaos testing

echo "Starting OpenShift QE Egress IP Scale Setup"
echo "==========================================="

# Configuration
EGRESS_IP_COUNT="${EGRESS_IP_COUNT:-5}"
EGRESS_NODES_COUNT="${EGRESS_NODES_COUNT:-10}"
SCALE_TEST_WORKLOADS="${SCALE_TEST_WORKLOADS:-20}"
NAMESPACE="openshift-ovn-kubernetes"

# Test artifacts directory
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Logging setup
LOG_FILE="$ARTIFACT_DIR/egress_ip_scale_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

error_exit() {
    log_error "$*"
    exit 1
}

# Validate cluster connectivity
log_info "Validating cluster connectivity..."
if ! oc cluster-info &> /dev/null; then
    error_exit "Cannot connect to OpenShift cluster. Please check your kubeconfig."
fi

# Deploy internal IP echo service for source IP validation
log_info "==============================="
log_info "STEP 1: Deploy Internal IP Echo Service"
log_info "==============================="
log_info "Deploying internal IP echo service for accurate source IP validation..."

# Check if internal echo service is already deployed
if oc get namespace egress-ip-validation &>/dev/null; then
    log_info "Internal IP echo service namespace already exists, checking service status..."
    if oc get service internal-ipecho -n egress-ip-validation &>/dev/null; then
        log_success "✅ Internal IP echo service already deployed"
        SERVICE_URL="http://internal-ipecho.egress-ip-validation.svc.cluster.local/"
        echo "$SERVICE_URL" > "$SHARED_DIR/internal-ipecho-url"
    fi
else
    log_info "Deploying new internal IP echo service..."
    
    # Create namespace
    oc create namespace egress-ip-validation
    
    # Deploy the service (using the same code from the dedicated step)
    cat << 'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: internal-ipecho
  namespace: egress-ip-validation
spec:
  replicas: 2
  selector:
    matchLabels:
      app: internal-ipecho
  template:
    metadata:
      labels:
        app: internal-ipecho
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: ipecho-server
        image: quay.io/openshift/origin-network-tools:latest
        command: ["/bin/bash", "-c"]
        args:
        - |
          cat > /tmp/ipecho-server.py << 'PYEOF'
          #!/usr/bin/env python3
          import socket
          import json
          from http.server import HTTPServer, BaseHTTPRequestHandler
          from urllib.parse import urlparse, parse_qs
          import datetime
          
          class IPEchoHandler(BaseHTTPRequestHandler):
              def do_GET(self):
                  client_ip = self.client_address[0]
                  response_data = {
                      "source_ip": client_ip,
                      "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
                      "method": self.command,
                      "path": self.path
                  }
                  self.send_response(200)
                  self.send_header('Content-type', 'application/json')
                  self.end_headers()
                  response_json = json.dumps(response_data, indent=2)
                  self.wfile.write(response_json.encode('utf-8'))
          
          if __name__ == '__main__':
              server = HTTPServer(('0.0.0.0', 8080), IPEchoHandler)
              print("Internal IP Echo Service starting on port 8080")
              server.serve_forever()
          PYEOF
          
          python3 /tmp/ipecho-server.py
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1001
          capabilities:
            drop:
            - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: internal-ipecho
  namespace: egress-ip-validation
spec:
  selector:
    app: internal-ipecho
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
EOF
    
    # Wait for service to be ready
    if oc wait --for=condition=ready pod -l app=internal-ipecho -n egress-ip-validation --timeout=120s; then
        SERVICE_URL="http://internal-ipecho.egress-ip-validation.svc.cluster.local/"
        echo "$SERVICE_URL" > "$SHARED_DIR/internal-ipecho-url"
        log_success "✅ Internal IP echo service deployed successfully"
        log_info "Service URL: $SERVICE_URL"
    else
        error_exit "Internal IP echo service failed to become ready"
    fi
fi

# Get cluster nodes and validate scale
log_info "Validating cluster scale requirements..."
mapfile -t worker_nodes < <(oc get nodes -l node-role.kubernetes.io/worker= --no-headers -o custom-columns=":metadata.name" | head -n "$EGRESS_NODES_COUNT")

if [[ ${#worker_nodes[@]} -lt $EGRESS_NODES_COUNT ]]; then
    error_exit "Insufficient worker nodes. Found ${#worker_nodes[@]}, need $EGRESS_NODES_COUNT"
fi

log_success "Found ${#worker_nodes[@]} worker nodes (required: $EGRESS_NODES_COUNT)"

# Phase 1: Configure all worker nodes as egress-assignable
log_info "==============================="
log_info "PHASE 1: Configure Egress Assignable Nodes"
log_info "==============================="

for node in "${worker_nodes[@]}"; do
    log_info "Configuring node $node as egress-assignable..."
    if oc label node "$node" k8s.ovn.org/egress-assignable=true --overwrite; then
        log_success "✅ Node $node labeled as egress-assignable"
    else
        log_warning "⚠️  Failed to label node $node, continuing..."
    fi
done

# Wait for nodes to be ready
log_info "Waiting for egress-assignable nodes to be ready..."
sleep 30

# Verify egress-assignable nodes
egress_ready_count=$(oc get nodes -l k8s.ovn.org/egress-assignable=true --no-headers | wc -l)
log_info "Egress-assignable nodes ready: $egress_ready_count/$EGRESS_NODES_COUNT"

# Phase 2: Create multiple egress IP configurations
log_info "==============================="
log_info "PHASE 2: Create Scale Egress IP Configurations"
log_info "==============================="

# Get available node IP ranges for egress IP allocation
log_info "Determining egress IP ranges from node networks..."
first_node_ip=$(oc get node "${worker_nodes[0]}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
network_prefix=$(echo "$first_node_ip" | cut -d. -f1-3)

# Create multiple egress IP configurations distributed across zones
for ((i=1; i<=EGRESS_IP_COUNT; i++)); do
    eip_name="egressip-scale-$i"
    eip_address="${network_prefix}.$(($((200 + i))))"
    
    log_info "Creating egress IP $i: $eip_name -> $eip_address"
    
    cat << EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: $eip_name
spec:
  egressIPs:
  - $eip_address
  namespaceSelector:
    matchLabels:
      egress-test-scale: "group-$i"
  podSelector:
    matchLabels:
      egress-pod-scale: "workload-$i"
EOF

    if [[ $? -eq 0 ]]; then
        log_success "✅ Created egress IP: $eip_name"
    else
        log_warning "⚠️  Failed to create egress IP: $eip_name"
    fi
done

# Phase 3: Wait for egress IP assignments
log_info "==============================="
log_info "PHASE 3: Validate Egress IP Assignments"
log_info "==============================="

log_info "Waiting for egress IP assignments (timeout: 300s)..."
assigned_count=0
elapsed=0
assignment_timeout=300

while [[ $assigned_count -lt $EGRESS_IP_COUNT ]] && [[ $elapsed -lt $assignment_timeout ]]; do
    assigned_count=0
    
    for ((i=1; i<=EGRESS_IP_COUNT; i++)); do
        eip_name="egressip-scale-$i"
        assigned_node=$(oc get egressip "$eip_name" -o jsonpath='{.status.items[0].node}' 2>/dev/null || echo "")
        
        if [[ -n "$assigned_node" ]]; then
            assigned_count=$((assigned_count + 1))
        fi
    done
    
    if [[ $assigned_count -lt $EGRESS_IP_COUNT ]]; then
        sleep 10
        elapsed=$((elapsed + 10))
        
        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log_info "Assigned egress IPs: $assigned_count/$EGRESS_IP_COUNT (elapsed: ${elapsed}s)"
        fi
    fi
done

if [[ $assigned_count -lt $EGRESS_IP_COUNT ]]; then
    log_warning "⚠️  Only $assigned_count/$EGRESS_IP_COUNT egress IPs assigned after ${assignment_timeout}s"
else
    log_success "✅ All $EGRESS_IP_COUNT egress IPs assigned successfully!"
fi

# Phase 4: Create test namespaces and workloads for scale testing
log_info "==============================="
log_info "PHASE 4: Create Scale Test Workloads"
log_info "==============================="

# Create test namespaces distributed across egress IP groups
for ((i=1; i<=EGRESS_IP_COUNT; i++)); do
    ns_name="egress-scale-test-$i"
    
    log_info "Creating test namespace: $ns_name"
    
    cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ns_name
  labels:
    egress-test-scale: "group-$i"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-workload-$i
  namespace: $ns_name
spec:
  replicas: 4
  selector:
    matchLabels:
      app: test-workload-$i
      egress-pod-scale: "workload-$i"
  template:
    metadata:
      labels:
        app: test-workload-$i
        egress-pod-scale: "workload-$i"
    spec:
      containers:
      - name: test-app
        image: quay.io/openshift/origin-network-tools:latest
        command: ["/bin/sleep", "3600"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
EOF

    if [[ $? -eq 0 ]]; then
        log_success "✅ Created test workload in namespace: $ns_name"
    else
        log_warning "⚠️  Failed to create workload in namespace: $ns_name"
    fi
done

# Phase 5: Wait for workload readiness
log_info "Waiting for test workloads to be ready..."
sleep 60

ready_workloads=0
for ((i=1; i<=EGRESS_IP_COUNT; i++)); do
    ns_name="egress-scale-test-$i"
    ready_replicas=$(oc get deployment -n "$ns_name" "test-workload-$i" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    if [[ "$ready_replicas" -eq 4 ]]; then
        ready_workloads=$((ready_workloads + 1))
        log_success "✅ Workload $i ready: $ready_replicas/4 replicas"
    else
        log_warning "⚠️  Workload $i partial: $ready_replicas/4 replicas ready"
    fi
done

# Phase 6: Baseline metrics collection
log_info "==============================="
log_info "PHASE 6: Collect Baseline Scale Metrics"
log_info "==============================="

log_info "Collecting baseline scale metrics..."

# Collect NAT rule counts across all OVN pods
total_nat_rules=0
ovn_pods=$(oc get pods -n "$NAMESPACE" -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$ovn_pods" ]]; then
    for pod in $ovn_pods; do
        nat_count=$(oc exec -n "$NAMESPACE" "$pod" -c ovnkube-controller -- bash -c \
            "ovn-nbctl --format=csv --no-heading find nat | grep egressip | wc -l" 2>/dev/null || echo "0")
        total_nat_rules=$((total_nat_rules + nat_count))
    done
fi

# Save scale baseline metrics
cat > "$ARTIFACT_DIR/scale_baseline_metrics.json" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "test_type": "egress_ip_scale_baseline",
  "cluster_config": {
    "total_worker_nodes": ${#worker_nodes[@]},
    "egress_assignable_nodes": $egress_ready_count,
    "egress_ip_count": $EGRESS_IP_COUNT,
    "assigned_egress_ips": $assigned_count,
    "test_workloads": $EGRESS_IP_COUNT,
    "ready_workloads": $ready_workloads
  },
  "ovn_metrics": {
    "total_nat_rules": $total_nat_rules,
    "ovn_pods_count": $(echo $ovn_pods | wc -w)
  }
}
EOF

# Final validation and summary
log_info "==============================="
log_info "SETUP VALIDATION & SUMMARY"
log_info "==============================="

log_success "🎯 Scale egress IP setup completed!"
log_info "Configuration Summary:"
log_info "  - Worker Nodes: ${#worker_nodes[@]}"
log_info "  - Egress-Assignable Nodes: $egress_ready_count/$EGRESS_NODES_COUNT"
log_info "  - Egress IPs Created: $EGRESS_IP_COUNT"
log_info "  - Egress IPs Assigned: $assigned_count/$EGRESS_IP_COUNT"
log_info "  - Test Workloads: $ready_workloads/$EGRESS_IP_COUNT ready"
log_info "  - Total NAT Rules: $total_nat_rules"
log_info "  - Setup Log: $LOG_FILE"

# Display current egress IP status
log_info "Current egress IP assignments:"
oc get egressip -o wide

# Validate readiness for chaos testing
if [[ $assigned_count -ge 3 ]] && [[ $ready_workloads -ge 3 ]]; then
    log_success "✅ Cluster ready for scaled chaos testing!"
    exit 0
else
    log_warning "⚠️  Cluster partially ready - some chaos tests may be limited"
    exit 0
fi