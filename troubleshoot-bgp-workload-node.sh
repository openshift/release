#!/bin/bash
# troubleshoot-bgp-workload-node.sh
# Comprehensive BGP troubleshooting for workload baremetal node

set -euo pipefail

# Configuration based on user's BGP output
WORKLOAD_NODE_IP="192.168.111.3"
BGP_NEIGHBORS="192.168.111.20,192.168.111.21"
LOCAL_AS="64512"
NEIGHBOR_AS="64512"  # iBGP session

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

log "🔍 BGP Troubleshooting for Workload Baremetal Node"
log "📍 Node: ${WORKLOAD_NODE_IP} | AS: ${LOCAL_AS}"
log "🔗 Neighbors: ${BGP_NEIGHBORS} | AS: ${NEIGHBOR_AS}"

# 1. Check basic network connectivity
test_connectivity() {
    log "🌐 Testing basic connectivity to BGP neighbors..."
    
    IFS=',' read -ra NEIGHBORS <<< "${BGP_NEIGHBORS}"
    for neighbor in "${NEIGHBORS[@]}"; do
        info "Testing connectivity to ${neighbor}..."
        
        # ICMP test
        if ping -c 3 -W 5 "${neighbor}" >/dev/null 2>&1; then
            info "✅ ICMP: ${neighbor} reachable"
        else
            error "❌ ICMP: ${neighbor} NOT reachable"
        fi
        
        # TCP port 179 test (BGP)
        if timeout 10 bash -c "echo >/dev/tcp/${neighbor}/179" 2>/dev/null; then
            info "✅ TCP:179: ${neighbor} BGP port accessible"
        else
            error "❌ TCP:179: ${neighbor} BGP port NOT accessible"
        fi
        
        # Check if neighbor is listening on BGP port
        if nmap -p 179 "${neighbor}" 2>/dev/null | grep -q "open"; then
            info "✅ BGP Service: ${neighbor} listening on port 179"
        else
            error "❌ BGP Service: ${neighbor} NOT listening on port 179"
        fi
        
        echo ""
    done
}

# 2. Check local BGP configuration
check_bgp_config() {
    log "📋 Checking local BGP configuration..."
    
    info "Current BGP summary:"
    oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp summary" || {
        error "Failed to get BGP summary - checking if FRR is running..."
        oc get pods -n workload-frr
        return 1
    }
    
    echo ""
    info "BGP neighbor details:"
    IFS=',' read -ra NEIGHBORS <<< "${BGP_NEIGHBORS}"
    for neighbor in "${NEIGHBORS[@]}"; do
        info "Neighbor ${neighbor} details:"
        oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp neighbors ${neighbor}" || {
            warn "Could not get details for neighbor ${neighbor}"
        }
        echo ""
    done
    
    info "Current FRR configuration:"
    oc exec -n workload-frr deployment/external-frr-workload -- cat /etc/frr/frr.conf
}

# 3. Check for iBGP vs eBGP configuration issues
analyze_bgp_session_type() {
    log "🔄 Analyzing BGP session type (iBGP vs eBGP)..."
    
    if [ "${LOCAL_AS}" = "${NEIGHBOR_AS}" ]; then
        info "🔗 Detected: iBGP session (same AS ${LOCAL_AS})"
        info "📋 iBGP requirements:"
        info "   • Next-hop-self may be needed"
        info "   • Route-reflector or full-mesh required"
        info "   • IGP connectivity required"
        
        # Check if route-reflector configuration is needed
        warn "⚠️  iBGP sessions require special configuration:"
        warn "   1. Ensure IGP routing (OSPF/static routes) between nodes"
        warn "   2. Configure route-reflector or full-mesh"
        warn "   3. Set next-hop-self for route advertisements"
        
    else
        info "🔗 Detected: eBGP session (AS ${LOCAL_AS} → AS ${NEIGHBOR_AS})"
        info "📋 eBGP requirements:"
        info "   • Direct connectivity or static routes"
        info "   • Different AS numbers"
        info "   • No special next-hop handling needed"
    fi
}

# 4. Check firewall and networking
check_networking() {
    log "🔥 Checking firewall and networking..."
    
    info "Local network interfaces:"
    ip addr show | grep -E "(inet|mtu)"
    
    echo ""
    info "Local routing table:"
    ip route | head -10
    
    echo ""
    info "Checking for firewall rules blocking BGP..."
    
    # Check iptables
    if command -v iptables >/dev/null; then
        info "iptables rules (relevant to BGP):"
        iptables -L | grep -E "(179|DROP|REJECT)" || info "No blocking rules found"
    fi
    
    # Check if SELinux might be blocking
    if command -v getenforce >/dev/null; then
        SELINUX_STATUS=$(getenforce)
        info "SELinux status: ${SELINUX_STATUS}"
        if [ "${SELINUX_STATUS}" = "Enforcing" ]; then
            warn "⚠️  SELinux is enforcing - may block BGP connections"
        fi
    fi
}

# 5. Generate corrected BGP configuration
generate_corrected_config() {
    log "🔧 Generating corrected BGP configuration..."
    
    # Check what the actual cluster nodes are
    info "Discovering actual OpenShift BGP speakers..."
    
    # Try to find OVN-K8s BGP configuration
    BGP_SPEAKERS=$(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | tr ' ' '\n' | grep "192.168.111" | head -3 || echo "")
    
    if [ -n "${BGP_SPEAKERS}" ]; then
        info "Found potential BGP speakers:"
        echo "${BGP_SPEAKERS}"
    else
        warn "Could not auto-discover BGP speakers"
        BGP_SPEAKERS="192.168.111.20,192.168.111.21"
    fi
    
    cat > /tmp/corrected-frr-config.conf << EOF
frr version 8.4
frr defaults traditional
hostname workload-frr-external-corrected
service integrated-vtysh-config

# Logging
log file /var/log/frr/bgpd.log
log timestamp precision 3
debug bgp neighbor-events
debug bgp updates

# BGP Configuration (iBGP)
router bgp ${LOCAL_AS}
 bgp router-id ${WORKLOAD_NODE_IP}
 bgp log-neighbor-changes
 bgp bestpath as-path multipath-relax
 no bgp default ipv4-unicast
 
 # iBGP neighbors (OpenShift cluster nodes)
$(echo "${BGP_NEIGHBORS}" | tr ',' '\n' | while read neighbor; do
cat << NEIGHBOR_EOF
 neighbor ${neighbor} remote-as ${NEIGHBOR_AS}
 neighbor ${neighbor} description "OCP BGP Speaker"
 neighbor ${neighbor} timers 3 9
 neighbor ${neighbor} timers connect 10
 neighbor ${neighbor} update-source ${WORKLOAD_NODE_IP}
NEIGHBOR_EOF
done)
 
 # Address family configuration
 address-family ipv4 unicast
$(echo "${BGP_NEIGHBORS}" | tr ',' '\n' | while read neighbor; do
cat << AF_EOF
  neighbor ${neighbor} activate
  neighbor ${neighbor} next-hop-self
  neighbor ${neighbor} route-map vm-routes-in in
  neighbor ${neighbor} route-map vm-routes-out out
AF_EOF
done)
  
  # Redistribute VM networks
  redistribute connected route-map connected-to-bgp
  redistribute static route-map static-to-bgp
 exit-address-family

# Route maps for filtering and modification
route-map vm-routes-in permit 10
 match ip address prefix-list vm-subnets
 set local-preference 200

route-map vm-routes-out permit 10
 match ip address prefix-list vm-subnets

route-map connected-to-bgp permit 10
 match ip address prefix-list vm-subnets

route-map static-to-bgp permit 10
 match ip address prefix-list vm-subnets

# Prefix lists for VM networks
ip prefix-list vm-subnets seq 5 permit 192.168.100.0/24 le 32
ip prefix-list vm-subnets seq 10 permit 10.128.0.0/14 le 32

line vty
 exec-timeout 0 0
EOF
    
    info "✅ Corrected FRR configuration saved to /tmp/corrected-frr-config.conf"
    
    cat > /tmp/update-frr-config.sh << 'UPDATE_EOF'
#!/bin/bash
# Update FRR configuration

echo "🔧 Updating FRR configuration..."

# Backup current config
oc exec -n workload-frr deployment/external-frr-workload -- cp /etc/frr/frr.conf /etc/frr/frr.conf.backup

# Update configuration
oc create configmap workload-frr-config-corrected --from-file=frr.conf=/tmp/corrected-frr-config.conf -n workload-frr --dry-run=client -o yaml | oc apply -f -

# Update deployment to use new config
oc patch deployment external-frr-workload -n workload-frr -p '{"spec":{"template":{"spec":{"volumes":[{"name":"frr-config","configMap":{"name":"workload-frr-config-corrected"}}]}}}}'

# Restart FRR pod
oc rollout restart deployment/external-frr-workload -n workload-frr

echo "✅ FRR configuration updated - waiting for pod restart..."
oc rollout status deployment/external-frr-workload -n workload-frr --timeout=120s

echo "🔍 New BGP status:"
sleep 30
oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c "show ip bgp summary"
UPDATE_EOF
    
    chmod +x /tmp/update-frr-config.sh
    info "✅ Update script saved to /tmp/update-frr-config.sh"
}

# 6. Check OpenShift BGP configuration
check_openshift_bgp() {
    log "🔍 Checking OpenShift BGP configuration..."
    
    info "Looking for OVN-K8s BGP configuration..."
    
    # Check for BGP-related resources
    if oc get crd | grep -q bgp; then
        info "BGP CRDs found:"
        oc get crd | grep bgp
        
        info "BGP configurations:"
        oc get bgpconfigurations -A 2>/dev/null || info "No BGP configurations found"
        oc get bgppeer -A 2>/dev/null || info "No BGP peers found"
    else
        warn "⚠️  No BGP CRDs found - OVN-K8s BGP may not be enabled"
    fi
    
    # Check OVN-K8s pods
    info "OVN-Kubernetes pods:"
    oc get pods -n openshift-ovn-kubernetes | grep -E "(ovnkube|ovn)" | head -5
    
    # Check for BGP-related logs
    info "Checking OVN-K8s logs for BGP mentions..."
    oc logs -n openshift-ovn-kubernetes deployment/ovnkube-control-plane --tail=100 2>/dev/null | grep -i bgp | tail -5 || info "No BGP logs found in OVN-K8s"
}

# 7. Provide resolution steps
provide_resolution_steps() {
    log "💡 BGP Session Resolution Steps"
    
    echo ""
    info "🔧 Immediate Actions:"
    echo "1. Update FRR configuration for iBGP:"
    echo "   cd /tmp && ./update-frr-config.sh"
    echo ""
    echo "2. Verify connectivity to neighbors:"
    IFS=',' read -ra NEIGHBORS <<< "${BGP_NEIGHBORS}"
    for neighbor in "${NEIGHBORS[@]}"; do
        echo "   ping -c 3 ${neighbor}"
        echo "   telnet ${neighbor} 179"
    done
    echo ""
    echo "3. Check OpenShift BGP speakers:"
    echo "   oc get nodes -o wide"
    echo "   oc describe node <node-with-bgp>"
    echo ""
    echo "4. Enable BGP in OpenShift (if not enabled):"
    echo "   # Check if OVN-K8s BGP is configured"
    echo "   oc get network.operator cluster -o yaml | grep -A 10 bgp"
    echo ""
    
    info "🔍 Verification Commands:"
    echo "   # Check BGP sessions"
    echo "   oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c 'show ip bgp summary'"
    echo ""
    echo "   # Check BGP routes"
    echo "   oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c 'show ip bgp'"
    echo ""
    echo "   # Check BGP neighbor details"
    echo "   oc exec -n workload-frr deployment/external-frr-workload -- vtysh -c 'show ip bgp neighbors'"
    echo ""
    
    warn "⚠️  Common Issues:"
    echo "   • iBGP requires next-hop-self configuration"
    echo "   • Firewall blocking TCP port 179"
    echo "   • OpenShift BGP not enabled/configured"
    echo "   • Network connectivity issues between nodes"
    echo "   • Incorrect AS numbers in configuration"
}

# Main execution
main() {
    test_connectivity
    check_bgp_config
    analyze_bgp_session_type
    check_networking
    check_openshift_bgp
    generate_corrected_config
    provide_resolution_steps
    
    log "🎯 Troubleshooting completed!"
    log "📋 Key findings saved to /tmp/corrected-frr-config.conf"
    log "🔧 Run: /tmp/update-frr-config.sh to apply fixes"
}

main "$@" 