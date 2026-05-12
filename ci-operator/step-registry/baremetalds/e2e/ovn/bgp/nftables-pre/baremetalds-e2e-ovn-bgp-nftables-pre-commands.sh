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
set -o nounset
set -o errexit
set -o pipefail
# Configure nftables rules for OpenShift NoOverlay pod to kubernetes service connectivity on bootstrap node

echo "$(date): Applying nftables rules for OpenShift NoOverlay pod to kubernetes service on bootstrap node connectivity..."

# Define cluster network CIDRs
CLUSTER_NETWORK_V4="10.128.0.0/14"
CLUSTER_NETWORK_V6="fd01::/48"
BOOTSTRAP_NETWORK="192.168.111.0/24"
BOOTSTRAP_NETWORK_V6="fd2e:6f44:5dd8:c956::/64"
INTERFACE_NAME="ostestbm"

# Enable IP forwarding (CRITICAL for NoOverlay routing)
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# --- Dedicated nft tables for NoOverlay forwarding and NAT ---
# Place NoOverlay rules in separate tables (openshift_nooverlay) so they are
# independent of firewalld.  firewalld only manages its own tables (e.g.
# "inet firewalld") and will not flush or interfere with tables it does not
# own.  nftables evaluates every registered base-chain at each hook point,
# so our chains work alongside firewalld without conflict or the need to
# stop it.  Priority -1 ensures evaluation before the default (priority 0)
# filter/nat chains.

# IPv4 forwarding and NAT
nft add table ip openshift_nooverlay
nft flush table ip openshift_nooverlay
nft add chain ip openshift_nooverlay forward "{ type filter hook forward priority -1 ; policy accept ; }"
nft add chain ip openshift_nooverlay postrouting "{ type nat hook postrouting priority -1 ; policy accept ; }"

nft add rule ip openshift_nooverlay forward iifname "${INTERFACE_NAME}" ip saddr "${CLUSTER_NETWORK_V4}" accept
nft add rule ip openshift_nooverlay forward oifname "${INTERFACE_NAME}" ip daddr "${CLUSTER_NETWORK_V4}" ct state related,established accept
echo "Added IPv4 FORWARD rules in openshift_nooverlay table"

nft add rule ip openshift_nooverlay postrouting ip saddr "${CLUSTER_NETWORK_V4}" ip daddr != "${BOOTSTRAP_NETWORK}" masquerade
echo "Added IPv4 MASQUERADE rule in openshift_nooverlay table"

# IPv6 forwarding and NAT
nft add table ip6 openshift_nooverlay
nft flush table ip6 openshift_nooverlay
nft add chain ip6 openshift_nooverlay forward "{ type filter hook forward priority -1 ; policy accept ; }"
nft add chain ip6 openshift_nooverlay postrouting "{ type nat hook postrouting priority -1 ; policy accept ; }"

nft add rule ip6 openshift_nooverlay forward iifname "${INTERFACE_NAME}" ip6 saddr "${CLUSTER_NETWORK_V6}" accept
nft add rule ip6 openshift_nooverlay forward oifname "${INTERFACE_NAME}" ip6 daddr "${CLUSTER_NETWORK_V6}" ct state related,established accept
echo "Added IPv6 FORWARD rules in openshift_nooverlay table"

nft add rule ip6 openshift_nooverlay postrouting ip6 saddr "${CLUSTER_NETWORK_V6}" ip6 daddr != "${BOOTSTRAP_NETWORK_V6}" masquerade
echo "Added IPv6 MASQUERADE rule in openshift_nooverlay table"

# --- Modifications to non-firewalld chains ---
# The chains below are managed by podman (NETAVARK_FORWARD) and libvirt
# (LIBVIRT_PRT), not by firewalld, so direct modification is safe.

# Remove ct state invalid drop rule from NETAVARK_FORWARD.
# In NoOverlay mode pod traffic arrives at the hypervisor via BGP-learned
# routes with no prior conntrack entry.  Conntrack marks these packets as
# "invalid" and netavark's default rule drops them.
if nft list chain ip filter NETAVARK_FORWARD 2>/dev/null | grep -q "ct state invalid.*drop"; then
    HANDLE=$(nft --handle list chain ip filter NETAVARK_FORWARD 2>/dev/null | grep "ct state invalid.*drop" | awk '{print $NF}')
    if [ -n "$HANDLE" ]; then
        nft delete rule ip filter NETAVARK_FORWARD handle "$HANDLE"
        echo "Removed ct state invalid drop from NETAVARK_FORWARD"
    fi
fi

# Add NAT RETURN rule in libvirt's LIBVIRT_PRT chain to skip masquerading
# for bootstrap-to-pod traffic.  Without this, libvirt rewrites the source
# IP and pods cannot route replies back via BGP.
if nft list chain ip nat LIBVIRT_PRT 2>/dev/null > /dev/null; then
    if ! nft list chain ip nat LIBVIRT_PRT 2>/dev/null | head -5 | grep -q "${CLUSTER_NETWORK_V4}"; then
        HANDLE=$(nft --handle list chain ip nat LIBVIRT_PRT 2>/dev/null | grep "${CLUSTER_NETWORK_V4}" | awk '{print $NF}' | head -1)
        if [ -n "$HANDLE" ]; then
            sudo nft delete rule ip nat LIBVIRT_PRT handle "$HANDLE"
        fi
        sudo nft insert rule ip nat LIBVIRT_PRT index 0 ip saddr "${BOOTSTRAP_NETWORK}" ip daddr "${CLUSTER_NETWORK_V4}" counter return
        echo "Added NAT RETURN rule at top of LIBVIRT_PRT for cluster-to-pod traffic"
    fi
fi

echo "$(date): nftables rules applied successfully"
EOFSCRIPT

# Make the script executable
sudo chmod +x /usr/local/bin/fix-openshift-firewall.sh

# Step 2: Create wrapper script that waits for master VMs
echo "Creating /usr/local/bin/wait-and-apply-firewall-rules.sh..."
sudo tee /usr/local/bin/wait-and-apply-firewall-rules.sh > /dev/null <<'EOFWAIT'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
echo "$(date): Waiting for master VMs to appear in virsh list..."
TIMEOUT=3600   # 1 hour max wait
ELAPSED=0
INTERVAL=300    # Check every 300 seconds

while true; do
    if command -v virsh &>/dev/null && virsh list --state-running 2>/dev/null | grep -qi "master"; then
        echo "$(date): Master VMs detected, applying nftables rules..."
        if /usr/local/bin/fix-openshift-firewall.sh; then
            echo "$(date): nftables rules applied successfully."
            exit 0
        fi
        echo "$(date): ERROR: Failed to apply nftables rules." >&2
        exit 1
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
