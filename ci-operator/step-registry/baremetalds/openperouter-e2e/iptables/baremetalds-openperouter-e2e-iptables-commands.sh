#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter firewalld fix for bootstrap gather ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# The installer's bootstrap gather runs on the bootstrap node and SSHes to every
# NIC address of every cluster node. The extra-network (toswitch1/toswitch2)
# addresses are unreachable, and the IPv6 ones in particular stall for ~7min each
# (TCP half-opens, then the SSH key exchange is reset), adding well over an hour
# to the gather. bootstrap->toswitch traffic is *routed* between libvirt bridges
# through the dev-scripts host, so it traverses this host's FORWARD chain. We add
# REJECT --reject-with tcp-reset rules there so those SYNs get an immediate RST
# instead of stalling, turning each ~7min stall into an instant failure.
#
# Notes:
# - Rules go in FORWARD (routed node-to-node gather traffic) and OUTPUT
#   (host-originated `openshift-install gather bootstrap` legs).
# - We use firewalld --permanent rules, NOT raw `iptables -I`. dev-scripts runs
#   `firewall-cmd --reload` during setup, which flushes manually-inserted rules;
#   permanent firewalld rules survive the reload.
# - Only tcp/22 to the toswitch subnets is rejected; the EVPN/SRv6 fabric uses
#   BGP/BFD/VXLAN, not SSH, so the fabric E2E is unaffected.
# - Link-local (fe80::) gather attempts are on-link and never routed through this
#   host, so they cannot be intercepted here.

# Parse subnet vars from DEVSCRIPTS_CONFIG
eval "${DEVSCRIPTS_CONFIG}"

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- \
  "${TOSWITCH1_NETWORK_SUBNET_V4}" "${TOSWITCH2_NETWORK_SUBNET_V4}" \
  "${TOSWITCH1_NETWORK_SUBNET_V6}" "${TOSWITCH2_NETWORK_SUBNET_V6}" << 'EOFFIREWALL'
set -euo pipefail

# dev-scripts depends on firewalld; make sure it is running before we add rules.
systemctl is-active --quiet firewalld || systemctl start firewalld

# add_reject <ipv4|ipv6> <subnet>: reject tcp/22 to <subnet> on FORWARD + OUTPUT
add_reject() {
  local family="$1" subnet="$2" chain
  for chain in FORWARD OUTPUT; do
    firewall-cmd --permanent --direct --add-rule "${family}" filter "${chain}" 0 \
      -p tcp -d "${subnet}" --dport 22 -j REJECT --reject-with tcp-reset
  done
}

add_reject ipv4 "$1"
add_reject ipv4 "$2"
add_reject ipv6 "$3"
add_reject ipv6 "$4"

# Apply permanent -> runtime.
firewall-cmd --reload

echo "Added firewalld REJECT(tcp-reset) rules for toswitch subnets on FORWARD+OUTPUT"
firewall-cmd --direct --get-all-rules
EOFFIREWALL
