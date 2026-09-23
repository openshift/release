#!/bin/bash

set -o nounset
set -o pipefail

echo "Deprovisioning ipecho server from dev-scripts host"

source "${SHARED_DIR}/packet-conf.sh"

# SSH to host and clean up ipecho service; all errors absorbed
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s << 'EOF' || true
systemctl stop ipecho.service || true
systemctl disable ipecho.service || true
rm -f /etc/systemd/system/ipecho.service || true
rm -f /usr/local/bin/ipecho.py || true
systemctl daemon-reload || true
echo "ipecho server cleaned up"
EOF

echo "ipecho deprovision complete"
