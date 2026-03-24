#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${NO_OVERLAY_OUTBOUND_SNAT:-Enabled}" = "Enabled" ]; then
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


# Step 1: Create the fix-openshift-firewall.sh script
echo "Creating /usr/local/bin/fix-openshift-firewall.sh..."
sudo tee /usr/local/bin/fix-openshift-firewall.sh > /dev/null <<'EOFSCRIPT'
#!/bin/bash
# Configure nftables rules for OpenShift NoOverlay pod to kubernetes service connectivity on bootstrap node

echo "$(date): Applying nftables rules for OpenShift NoOverlay pod to kubernetes service on bootstrap node connectivity..."

# Define cluster network CIDRs
CLUSTER_NETWORK_V4="10.128.0.0/14"
CLUSTER_NETWORK_V6="fd01::/48"
BOOTSTRAP_NETWORK="192.168.111.0/24"
BOOTSTRAP_NETWORK_V6="fd2e:6f44:5dd8:c956::/64"
INTERFACE_NAME="ostestbm"

# Function to add nftables FORWARD rules for a given IP family
# Using native nft commands since firewalld is stopped
add_forward_rules() {
    local cluster_network=$1
    local family=$2   # ip | ip6

    # Check if egress rule exists
    if ! nft list chain "${family}" filter FORWARD 2>/dev/null | grep -q "iifname \"${INTERFACE_NAME}\" ${family} saddr ${cluster_network}"; then
        sudo nft insert rule "${family}" filter FORWARD iifname "${INTERFACE_NAME}" "${family}" saddr "${cluster_network}" accept || true
        echo "Added ${family} FORWARD rule for cluster network egress"
    fi

    # Check if return traffic rule exists
    if ! nft list chain "${family}" filter FORWARD 2>/dev/null | grep -q "oifname \"${INTERFACE_NAME}\" ${family} daddr ${cluster_network}.*established"; then
        sudo nft insert rule "${family}" filter FORWARD oifname "${INTERFACE_NAME}" "${family}" daddr "${cluster_network}" ct state related,established accept || true
        echo "Added ${family} FORWARD rule for cluster network return traffic"
    fi
}

add_masquerade_rule() {
    local cluster_network=$1
    local bootstrap_network=$2
    local family=$3   # ip | ip6

    # Check if masquerade rule exists
    if ! nft list chain "${family}" nat POSTROUTING 2>/dev/null | grep -q "${family} saddr ${cluster_network}.*masquerade"; then
        sudo nft insert rule "${family}" nat POSTROUTING "${family}" saddr "${cluster_network}" "${family}" daddr != "${bootstrap_network}" masquerade || true
        echo "Added ${family} MASQUERADE rule for cluster network egress"
    fi
}

# Stop and disable firewalld to prevent rule conflicts
systemctl stop firewalld || true
systemctl disable firewalld || true

# Enable IP forwarding (CRITICAL for NoOverlay routing)
sysctl -w net.ipv4.ip_forward=1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 || true

# Remove ct state invalid drop rule from NETAVARK_FORWARD
if nft list chain ip filter NETAVARK_FORWARD 2>/dev/null | grep -q "ct state invalid.*drop"; then
    HANDLE=$(nft --handle list chain ip filter NETAVARK_FORWARD 2>/dev/null | grep "ct state invalid.*drop" | awk '{print $NF}')
    if [ -n "$HANDLE" ]; then
        nft delete rule ip filter NETAVARK_FORWARD handle $HANDLE
        echo "Removed ct state invalid drop from NETAVARK_FORWARD"
    fi
fi

# Add NAT RETURN rule to skip masquerading for cluster-to-pod traffic from bootstrap host.
# Must be at the beginning of the chain to match before any masquerade rules.
if nft list chain ip nat LIBVIRT_PRT 2>/dev/null > /dev/null; then
    if ! nft list chain ip nat LIBVIRT_PRT 2>/dev/null | head -5 | grep -q "${CLUSTER_NETWORK_V4}"; then
        HANDLE=$(nft --handle list chain ip nat LIBVIRT_PRT 2>/dev/null | grep "${CLUSTER_NETWORK_V4}" | awk '{print $NF}' | head -1)
        if [ -n "$HANDLE" ]; then
            sudo nft delete rule ip nat LIBVIRT_PRT handle "$HANDLE" || true
        fi
        sudo nft insert rule ip nat LIBVIRT_PRT index 0 ip saddr "${BOOTSTRAP_NETWORK}" ip daddr "${CLUSTER_NETWORK_V4}" counter return || true
        echo "Added NAT RETURN rule at top of LIBVIRT_PRT for cluster-to-pod traffic"
    fi
fi

# IPv4 rules
add_forward_rules   "${CLUSTER_NETWORK_V4}" "ip"
add_masquerade_rule "${CLUSTER_NETWORK_V4}" "${BOOTSTRAP_NETWORK}"    "ip"

# IPv6 rules
add_forward_rules   "${CLUSTER_NETWORK_V6}" "ip6"
add_masquerade_rule "${CLUSTER_NETWORK_V6}" "${BOOTSTRAP_NETWORK_V6}" "ip6"

echo "$(date): nftables rules applied successfully"
EOFSCRIPT

# Make the script executable
sudo chmod +x /usr/local/bin/fix-openshift-firewall.sh

# Step 2: Create wrapper script that waits for master VMs
echo "Creating /usr/local/bin/wait-and-apply-firewall-rules.sh..."
sudo tee /usr/local/bin/wait-and-apply-firewall-rules.sh > /dev/null <<'EOFWAIT'
#!/bin/bash
echo "$(date): Waiting for master VMs to appear in virsh list..."
TIMEOUT=3600   # 1 hour max wait
ELAPSED=0
INTERVAL=300    # Check every 300 seconds

while true; do
    if command -v virsh &>/dev/null && virsh list --state-running 2>/dev/null | grep -qi "master"; then
        echo "$(date): Master VMs detected, applying nftables rules..."
        /usr/local/bin/fix-openshift-firewall.sh
        echo "$(date): nftables rules applied successfully."
        exit 0
    fi
    if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
        echo "$(date): WARNING: Timed out after ${TIMEOUT}s waiting for master VMs."
        exit 1
    fi
    sleep "${INTERVAL}"
    ELAPSED=$(( ELAPSED + INTERVAL ))
done
EOFWAIT
sudo chmod +x /usr/local/bin/wait-and-apply-firewall-rules.sh

# Step 3: Create systemd service to run the wait-and-apply script
echo "Creating /etc/systemd/system/apply-openshift-firewall-rules.service..."
sudo tee /etc/systemd/system/apply-openshift-firewall-rules.service > /dev/null <<'EOFSERVICE'
[Unit]
Description=Wait for master VMs and apply nftables rules for OpenShift NoOverlay
After=libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wait-and-apply-firewall-rules.sh
TimeoutStartSec=3700
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFSERVICE

# Step 4: Enable and start the service
echo "Enabling and starting apply-openshift-firewall-rules.service..."
sudo systemctl daemon-reload
sudo systemctl enable apply-openshift-firewall-rules.service
sudo systemctl start --no-block apply-openshift-firewall-rules.service

echo "Service started in background. Check status with: systemctl status apply-openshift-firewall-rules.service"

EOFNFTABLES

echo "nftables rules configured on remote server"
