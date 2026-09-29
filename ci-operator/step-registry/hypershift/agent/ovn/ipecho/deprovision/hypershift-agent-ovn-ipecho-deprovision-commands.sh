#!/bin/bash

set -o nounset
set -o pipefail

echo "Deprovisioning ipecho server from dev-scripts host"

source "${SHARED_DIR}/packet-conf.sh"

# Written by the provision step only when the echo target was moved off the plain bridge
# address. The provisioning host outlives the cluster, so a leftover subinterface would
# collide with the next job that asks for the same tag, and a leftover dummy would keep
# answering for an address the next job may place elsewhere.
IPECHO_VLAN_ID=""
if [[ -f "${SHARED_DIR}/ipecho_vlan_id" ]]; then
  IPECHO_VLAN_ID="$(cat "${SHARED_DIR}/ipecho_vlan_id")"
fi
IPECHO_REMOTE_IFACE=""
if [[ -f "${SHARED_DIR}/ipecho_remote_iface" ]]; then
  IPECHO_REMOTE_IFACE="$(cat "${SHARED_DIR}/ipecho_remote_iface")"
fi

# SSH to host and clean up ipecho service; all errors absorbed
# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IPECHO_VLAN_ID}" "${IPECHO_REMOTE_IFACE}" << 'EOF' || true
IPECHO_VLAN_ID="$1"
IPECHO_REMOTE_IFACE="$2"

systemctl stop ipecho.service || true
systemctl disable ipecho.service || true
rm -f /etc/systemd/system/ipecho.service || true
rm -f /usr/local/bin/ipecho.py || true
systemctl daemon-reload || true

if [[ -n "${IPECHO_VLAN_ID}" ]]; then
    # A VLAN link renders as "<parent>.<id>@<parent>", so the tag alone is enough to
    # find it without having to rediscover which bridge it was built on.
    for iface in $(ip -o link show \
        | awk -F': ' -v tag=".${IPECHO_VLAN_ID}@" 'index($2, tag) {split($2, a, "@"); print a[1]}'); do
        echo "removing VLAN subinterface ${iface}"
        ip link del "${iface}" || true
    done
fi

if [[ -n "${IPECHO_REMOTE_IFACE}" ]]; then
    echo "removing dummy link ${IPECHO_REMOTE_IFACE}"
    ip link del "${IPECHO_REMOTE_IFACE}" || true
fi

echo "ipecho server cleaned up"
EOF

echo "ipecho deprovision complete"
