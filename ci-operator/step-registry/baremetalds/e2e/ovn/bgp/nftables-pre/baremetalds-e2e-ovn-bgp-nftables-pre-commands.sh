#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${NO_OVERLAY_OUTBOUND_SNAT:-Enabled}" == "Enabled" ]; then
    echo "NoOverlay outboundSNAT is enabled, skipping nftables rules configuration"
    exit 0
fi

echo "************ baremetalds e2e ovn bgp nftables pre command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "Configuring nftables rules for NoOverlay networking and BGP..."

ssh "${SSHOPTS[@]}" "root@${IP}" bash -x << 'EOFNFTABLES'
set -o nounset
set -o errexit
set -o pipefail

echo "Setting up nftables rules for NoOverlay BGP cluster..."

# Ensure nftables is available
if ! command -v nft &> /dev/null; then
    echo "Installing nftables..."
    sudo dnf install -y nftables
fi

# Step 1: Create the fix-openshift-firewall.sh script
echo "Creating /usr/local/bin/fix-openshift-firewall.sh..."
sudo tee /usr/local/bin/fix-openshift-firewall.sh > /dev/null <<'EOFSCRIPT'
#!/bin/bash
# Fix nftables rules for OpenShift NoOverlay pod to kubernetes service on bootstrap node connectivity
# This script ensures proper nftables rules are maintained even if firewalld modifies them

echo "$(date): Applying nftables rules for OpenShift NoOverlay pod to kubernetes service on bootstrap node connectivity..."

# Enable IP forwarding (CRITICAL for NoOverlay routing)
sysctl -w net.ipv4.ip_forward=1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 || true

# Remove ct state invalid drop rule from NETAVARK_FORWARD
if nft list chain ip filter NETAVARK_FORWARD 2>/dev/null | grep -q "ct state invalid.*drop"; then
    HANDLE=$(nft --handle list chain ip filter NETAVARK_FORWARD 2>/dev/null | grep "ct state invalid.*drop" | awk '{print $NF}')
    if [ -n "$HANDLE" ]; then
        nft delete rule ip filter NETAVARK_FORWARD handle $HANDLE || true
        echo "Removed ct state invalid drop from NETAVARK_FORWARD"
    fi
fi

# Remove ct state invalid drop rule from firewalld filter_INPUT
if nft list chain inet firewalld filter_INPUT 2>/dev/null | grep -q "ct state invalid drop"; then
    HANDLE=$(nft --handle list chain inet firewalld filter_INPUT 2>/dev/null | grep "ct state invalid drop" | awk '{print $NF}')
    if [ -n "$HANDLE" ]; then
        nft delete rule inet firewalld filter_INPUT handle $HANDLE || true
        echo "Removed ct state invalid drop from filter_INPUT"
    fi
fi

# Remove ct state invalid drop rule from firewalld filter_FORWARD
if nft list chain inet firewalld filter_FORWARD 2>/dev/null | grep -q "ct state invalid drop"; then
    HANDLE=$(nft --handle list chain inet firewalld filter_FORWARD 2>/dev/null | grep "ct state invalid drop" | awk '{print $NF}')
    if [ -n "$HANDLE" ]; then
        nft delete rule inet firewalld filter_FORWARD handle $HANDLE || true
        echo "Removed ct state invalid drop from filter_FORWARD"
    fi
fi

# Add NAT RETURN rule to skip masquerading for cluster to pod traffic
# Must be at beginning (first rule) to match before masquerade rules
if nft list chain ip nat LIBVIRT_PRT 2>/dev/null >/dev/null; then
    if ! nft list chain ip nat LIBVIRT_PRT 2>/dev/null | head -5 | grep -q "10.128.0.0/14"; then
        # Remove any existing rule at wrong position
        HANDLE=$(nft --handle list chain ip nat LIBVIRT_PRT 2>/dev/null | grep "10.128.0.0/14" | awk '{print $NF}' | head -1)
        if [ -n "$HANDLE" ]; then
            nft delete rule ip nat LIBVIRT_PRT handle $HANDLE || true
        fi
        # Insert at beginning of chain
        nft insert rule ip nat LIBVIRT_PRT ip saddr 192.168.111.0/24 ip daddr 10.128.0.0/14 counter return || true
        echo "Added NAT RETURN rule at top of chain for cluster to pod traffic"
    fi
fi

# Add nftables rules for pod egress connectivity
CLUSTER_NETWORK_V4="10.128.0.0/14"
CLUSTER_NETWORK_V6="fd01::/48"

# IPv4 rules
# Allow forwarding from cluster network
if ! nft list chain ip filter FORWARD 2>/dev/null | grep -q "ip saddr ${CLUSTER_NETWORK_V4} iifname \"ostestbm\""; then
    nft insert rule ip filter FORWARD iifname "ostestbm" ip saddr ${CLUSTER_NETWORK_V4} counter accept || true
    echo "Added IPv4 FORWARD rule for cluster network egress"
fi

# Allow return traffic to cluster network
if ! nft list chain ip filter FORWARD 2>/dev/null | grep -q "ip daddr ${CLUSTER_NETWORK_V4} oifname \"ostestbm\""; then
    nft insert rule ip filter FORWARD oifname "ostestbm" ip daddr ${CLUSTER_NETWORK_V4} ct state related,established counter accept || true
    echo "Added IPv4 FORWARD rule for cluster network return traffic"
fi

# Masquerade pod traffic to external networks
if ! nft list chain ip nat POSTROUTING 2>/dev/null | head -5 | grep -q "ip saddr ${CLUSTER_NETWORK_V4} ip daddr != 192.168.111.0/24.*masquerade"; then
    nft insert rule ip nat POSTROUTING ip saddr ${CLUSTER_NETWORK_V4} ip daddr != 192.168.111.0/24 counter masquerade || true
    echo "Added IPv4 MASQUERADE rule for cluster network egress"
fi

# IPv6 rules
# Allow forwarding from cluster network (IPv6)
if ! nft list chain ip6 filter FORWARD 2>/dev/null | grep -q "ip6 saddr ${CLUSTER_NETWORK_V6} iifname \"ostestbm\""; then
    nft insert rule ip6 filter FORWARD iifname "ostestbm" ip6 saddr ${CLUSTER_NETWORK_V6} counter accept || true
    echo "Added IPv6 FORWARD rule for cluster network egress"
fi

# Allow return traffic to cluster network (IPv6)
if ! nft list chain ip6 filter FORWARD 2>/dev/null | grep -q "ip6 daddr ${CLUSTER_NETWORK_V6} oifname \"ostestbm\""; then
    nft insert rule ip6 filter FORWARD oifname "ostestbm" ip6 daddr ${CLUSTER_NETWORK_V6} ct state related,established counter accept || true
    echo "Added IPv6 FORWARD rule for cluster network return traffic"
fi

# Masquerade pod traffic to external networks (IPv6)
if ! nft list chain ip6 nat POSTROUTING 2>/dev/null | head -5 | grep -q "ip6 saddr ${CLUSTER_NETWORK_V6} ip6 daddr != fd2e:6f44:5dd8:c956::/64.*masquerade"; then
    nft insert rule ip6 nat POSTROUTING ip6 saddr ${CLUSTER_NETWORK_V6} ip6 daddr != fd2e:6f44:5dd8:c956::/64 counter masquerade || true
    echo "Added IPv6 MASQUERADE rule for cluster network egress"
fi

echo "$(date): nftables rules applied successfully"
EOFSCRIPT

# Make the script executable
sudo chmod +x /usr/local/bin/fix-openshift-firewall.sh

# Step 2: Create the systemd service
echo "Creating /etc/systemd/system/fix-openshift-firewall.service..."
sudo tee /etc/systemd/system/fix-openshift-firewall.service > /dev/null <<'EOFSERVICE'
[Unit]
Description=Fix nftables rules for OpenShift pod connectivity
After=firewalld.service libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-openshift-firewall.sh
EOFSERVICE

# Step 3: Create the systemd timer
echo "Creating /etc/systemd/system/fix-openshift-firewall.timer..."
sudo tee /etc/systemd/system/fix-openshift-firewall.timer > /dev/null <<'EOFTIMER'
[Unit]
Description=Periodically fix nftables rules for OpenShift pod connectivity
After=firewalld.service

[Timer]
OnBootSec=30s
OnCalendar=*:0/2
Unit=fix-openshift-firewall.service

[Install]
WantedBy=timers.target
EOFTIMER

# Step 4: Enable and start the timer
echo "Enabling and starting fix-openshift-firewall timer..."
sudo systemctl daemon-reload
sudo systemctl enable fix-openshift-firewall.timer
sudo systemctl start fix-openshift-firewall.timer

# Run immediately to apply initial rules (IMPORTANT!)
echo "Running fix-openshift-firewall.sh immediately..."
sudo /usr/local/bin/fix-openshift-firewall.sh || true

# Verify the timer is active
echo "Verifying timer status..."
sudo systemctl status fix-openshift-firewall.timer --no-pager || true

# List upcoming timer executions
echo "Next scheduled timer runs:"
sudo systemctl list-timers fix-openshift-firewall.timer --no-pager || true

EOFNFTABLES

echo "nftables rules configured on remote server"
