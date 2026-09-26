#!/bin/bash

set -o nounset
set -o pipefail

echo "Deprovisioning ipecho server from dev-scripts host"

source "${SHARED_DIR}/packet-conf.sh"

# Written by the provision step only when the echo target was put on a VLAN. The
# provisioning host outlives the cluster, so a leftover subinterface would collide with
# the next job that asks for the same tag.
IPECHO_VLAN_ID=""
if [[ -f "${SHARED_DIR}/ipecho_vlan_id" ]]; then
  IPECHO_VLAN_ID="$(cat "${SHARED_DIR}/ipecho_vlan_id")"
fi

# SSH to host and clean up ipecho service; all errors absorbed
# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${IPECHO_VLAN_ID}" << 'EOF' || true
IPECHO_VLAN_ID="$1"

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

echo "ipecho server cleaned up"
EOF

echo "ipecho deprovision complete"
