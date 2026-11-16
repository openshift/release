#!/bin/bash

set -euo pipefail

if [[ ! -s "${SHARED_DIR}/server-ip" || ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  exit 0
fi
source "${SHARED_DIR}/packet-conf.sh"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s <<'EOF'
set -euo pipefail
podman rm -f minio >/dev/null 2>&1 || true
rm -rf /opt/minio/data /opt/minio/certs /root/minio-root.env
firewall-cmd --zone=libvirt --remove-port=9000/tcp || true
firewall-cmd --remove-port=9000/tcp || true
EOF
