#!/bin/bash
# diagnose-workload-node-connectivity.sh
# Diagnose workload node connectivity to OpenShift cluster

set -euo pipefail

# From user's error and BGP output
WORKLOAD_NODE="192.168.111.3"  # Current node
OCP_API_SERVER="192.168.111.5:6443"  # OpenShift API
BGP_NEIGHBORS="192.168.111.20,192.168.111.21"  # BGP peers
ES_SERVER="https://www.esurl.com:443"  # External ES

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }
info() { echo -e "${BLUE}[INFO] $1${NC}"; }

log "🔍 Diagnosing Workload Node Connectivity Issues"
log "📍 Workload Node: ${WORKLOAD_NODE}"
log "🎯 OpenShift API: ${OCP_API_SERVER}"

# 1. Basic network connectivity tests
test_basic_connectivity() {
    log "🌐 Testing basic network connectivity..."
    
    # Current node IP
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    info "Current node IP: ${CURRENT_IP}"
    
    if [ "${CURRENT_IP}" != "${WORKLOAD_NODE}" ]; then
        warn "⚠️  Expected workload node IP ${WORKLOAD_NODE}, but current IP is ${CURRENT_IP}"
    fi
    
    # Test OpenShift API connectivity
    OCP_API_IP=$(echo "${OCP_API_SERVER}" | cut -d: -f1)
    OCP_API_PORT=$(echo "${OCP_API_SERVER}" | cut -d: -f2)
    
    info "Testing OpenShift API server connectivity..."
    
    # ICMP test
    if ping -c 3 -W 5 "${OCP_API_IP}" >/dev/null 2>&1; then
        info "✅ ICMP: OpenShift API server ${OCP_API_IP} reachable"
    else
        error "❌ ICMP: OpenShift API server ${OCP_API_IP} NOT reachable"
    fi
    
    # TCP port test
    if timeout 10 bash -c "echo >/dev/tcp/${OCP_API_IP}/${OCP_API_PORT}" 2>/dev/null; then
        info "✅ TCP: OpenShift API ${OCP_API_SERVER} accessible"
    else
        error "❌ TCP: OpenShift API ${OCP_API_SERVER} NOT accessible"
    fi
    
    # Test BGP neighbors
    info "Testing BGP neighbor connectivity..."
    IFS=',' read -ra NEIGHBORS <<< "${BGP_NEIGHBORS}"
    for neighbor in "${NEIGHBORS[@]}"; do
        if ping -c 2 -W 3 "${neighbor}" >/dev/null 2>&1; then
            info "✅ BGP Neighbor ${neighbor} reachable"
        else
            error "❌ BGP Neighbor ${neighbor} NOT reachable"
        fi
    done
}

# 2. Check routing and network configuration
check_routing() {
    log "🛣️  Checking routing configuration..."
    
    info "Current routing table:"
    ip route | head -10
    
    echo ""
    info "Network interfaces:"
    ip addr show | grep -E "(inet|mtu)" | head -10
    
    echo ""
    info "DNS resolution test:"
    if nslookup "${OCP_API_IP}" >/dev/null 2>&1; then
        info "✅ DNS: Can resolve ${OCP_API_IP}"
    else
        warn "⚠️  DNS: Cannot resolve ${OCP_API_IP}"
    fi
    
    # Check for default gateway
    DEFAULT_GW=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "${DEFAULT_GW}" ]; then
        info "Default gateway: ${DEFAULT_GW}"
        if ping -c 2 -W 3 "${DEFAULT_GW}" >/dev/null 2>&1; then
            info "✅ Default gateway reachable"
        else
            error "❌ Default gateway NOT reachable"
        fi
    else
        error "❌ No default gateway found"
    fi
}

# 3. Check if we're actually on the correct node
verify_node_identity() {
    log "🆔 Verifying node identity..."
    
    info "Hostname: $(hostname)"
    info "All IP addresses:"
    hostname -I
    
    info "Network interfaces with IPs:"
    ip addr show | grep "inet " | grep -v "127.0.0.1"
    
    # Check if this node is part of OpenShift cluster
    info "Checking if this node is part of OpenShift cluster..."
    if command -v oc >/dev/null && oc whoami >/dev/null 2>&1; then
        CURRENT_USER=$(oc whoami 2>/dev/null || echo "not-logged-in")
        info "oc user: ${CURRENT_USER}"
        
        if [ "${CURRENT_USER}" != "not-logged-in" ]; then
            info "OpenShift nodes in cluster:"
            oc get nodes -o wide | head -5 || warn "Cannot get nodes"
        fi
    else
        warn "⚠️  oc command not available or not logged in"
    fi
}

# 4. Check firewall and security
check_security() {
    log "🔥 Checking firewall and security settings..."
    
    # Check iptables
    if command -v iptables >/dev/null; then
        info "iptables rules (first 10):"
        iptables -L | head -10 || warn "Cannot read iptables"
        
        info "iptables NAT rules:"
        iptables -t nat -L | head -5 || warn "Cannot read NAT rules"
    fi
    
    # Check SELinux
    if command -v getenforce >/dev/null; then
        SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
        info "SELinux status: ${SELINUX_STATUS}"
    fi
    
    # Check for NetworkManager
    if systemctl is-active NetworkManager >/dev/null 2>&1; then
        info "✅ NetworkManager is running"
    else
        warn "⚠️  NetworkManager is not running"
    fi
}

# 5. Test kube-burner prerequisites
test_kube_burner_prereqs() {
    log "🧪 Testing kube-burner prerequisites..."
    
    # Check if we can access OpenShift API using oc
    info "Testing OpenShift API access..."
    
    if oc cluster-info >/dev/null 2>&1; then
        info "✅ oc cluster-info successful"
        
        # Get cluster version
        CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
        info "OpenShift version: ${CLUSTER_VERSION}"
        
        # Test API connectivity directly
        info "Testing API endpoints..."
        if oc get nodes >/dev/null 2>&1; then
            info "✅ Can access nodes API"
        else
            error "❌ Cannot access nodes API"
        fi
        
        if oc get namespaces >/dev/null 2>&1; then
            info "✅ Can access namespaces API"
        else
            error "❌ Cannot access namespaces API"
        fi
        
    else
        error "❌ oc cluster-info failed"
        warn "This may be why kube-burner cannot connect"
    fi
    
    # Check if udn-bgp workload exists
    info "Checking for udn-bgp workload..."
    if ls bin/amd64/kube-burner-ocp >/dev/null 2>&1; then
        info "✅ kube-burner-ocp binary found"
        
        # List available workloads
        info "Available workloads:"
        bin/amd64/kube-burner-ocp --help 2>&1 | grep -A 20 "Available Commands:" | head -10 || {
            warn "Cannot get workload list"
        }
    else
        error "❌ kube-burner-ocp binary not found"
    fi
}

# 6. Generate connection fixes
generate_fixes() {
    log "🔧 Generating connection fixes..."
    
    cat > /tmp/fix-workload-node-connectivity.sh << 'FIX_EOF'
#!/bin/bash
# fix-workload-node-connectivity.sh

echo "🔧 Attempting to fix workload node connectivity..."

# 1. Check if we need to add routes
OCP_API_IP="192.168.111.5"
WORKLOAD_IP="192.168.111.3"

echo "Adding static route to OpenShift API if needed..."
if ! ip route | grep -q "${OCP_API_IP}"; then
    # Try to find the correct gateway
    GATEWAY=$(ip route | grep "192.168.111" | grep -v "192.168.111.3" | head -1 | awk '{print $1}' | cut -d/ -f1)
    if [ -n "${GATEWAY}" ]; then
        echo "Adding route: ${OCP_API_IP} via ${GATEWAY}"
        ip route add "${OCP_API_IP}/32" via "${GATEWAY}" 2>/dev/null || echo "Route may already exist"
    fi
fi

# 2. Test connectivity after route addition
echo "Testing connectivity after fixes..."
if ping -c 2 -W 3 "${OCP_API_IP}"; then
    echo "✅ Connectivity to OpenShift API restored"
else
    echo "❌ Still no connectivity to OpenShift API"
fi

# 3. Try to re-establish oc login
echo "Attempting to re-establish oc login..."
if [ -f ~/.kube/config ]; then
    echo "kubeconfig exists, testing connection..."
    oc cluster-info
else
    echo "⚠️  No kubeconfig found - may need to copy from bastion"
    echo "To fix: scp root@bastion:~/.kube/config ~/.kube/config"
fi

# 4. Test kube-burner connectivity
echo "Testing kube-burner connectivity..."
if oc get nodes >/dev/null 2>&1; then
    echo "✅ Can run kube-burner commands"
    echo "Try: bin/amd64/kube-burner-ocp <workload> --iterations 1 --log-level=debug"
else
    echo "❌ Still cannot connect - check networking and authentication"
fi
FIX_EOF
    
    chmod +x /tmp/fix-workload-node-connectivity.sh
    info "✅ Fix script saved to /tmp/fix-workload-node-connectivity.sh"
    
    cat > /tmp/alternative-kube-burner-approach.sh << 'ALT_EOF'
#!/bin/bash
# alternative-kube-burner-approach.sh
# Alternative approaches for running kube-burner

echo "🔄 Alternative kube-burner approaches..."

# 1. Run kube-burner from bastion/deployment node instead
echo "Option 1: Run from bastion/deployment node"
echo "  - SSH to deployment node where oc works"
echo "  - Copy kube-burner binary there"
echo "  - Run: bin/amd64/kube-burner-ocp udn-bgp --iterations 2"

# 2. Use port forwarding
echo ""
echo "Option 2: Use port forwarding for API access"
echo "  - From working node: oc port-forward --address=0.0.0.0 -n default svc/kubernetes 6443:443"
echo "  - Update kubeconfig to use localhost:6443"

# 3. Run without ES server initially
echo ""
echo "Option 3: Run without external ES server first"
echo "  bin/amd64/kube-burner-ocp udn-bgp --iterations 1 --log-level=debug"
echo "  (Remove --es-server parameter)"

# 4. Check available workloads
echo ""
echo "Option 4: Use existing workload instead of udn-bgp"
echo "Available workloads that might work for UDN testing:"
echo "  - cluster-density"
echo "  - node-density"
echo "  - networkpolicy-multitenant"

echo ""
echo "Recommended immediate action:"
echo "bin/amd64/kube-burner-ocp cluster-density --iterations 1 --log-level=debug"
ALT_EOF
    
    chmod +x /tmp/alternative-kube-burner-approach.sh
    info "✅ Alternative approaches saved to /tmp/alternative-kube-burner-approach.sh"
}

# Main execution
main() {
    test_basic_connectivity
    echo ""
    check_routing
    echo ""
    verify_node_identity
    echo ""
    check_security
    echo ""
    test_kube_burner_prereqs
    echo ""
    generate_fixes
    
    log "🎯 Diagnosis completed!"
    log ""
    log "📋 Summary of Issues Found:"
    if ! ping -c 1 -W 3 "192.168.111.5" >/dev/null 2>&1; then
        error "❌ Cannot reach OpenShift API server (192.168.111.5)"
    fi
    
    if ! oc cluster-info >/dev/null 2>&1; then
        error "❌ oc cannot connect to cluster"
    fi
    
    log ""
    log "🔧 Next Steps:"
    log "1. Run: /tmp/fix-workload-node-connectivity.sh"
    log "2. If still failing, try: /tmp/alternative-kube-burner-approach.sh"
    log "3. Consider running kube-burner from deployment/bastion node instead"
}

main "$@" 