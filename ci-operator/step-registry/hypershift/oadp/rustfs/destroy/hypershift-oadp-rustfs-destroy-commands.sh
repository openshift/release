#!/bin/bash

set -euo pipefail

if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  exit 0
fi

source "${SHARED_DIR}/packet-conf.sh"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s <<'HOST'
set -euo pipefail
rm -f /root/rustfs.env
if [[ ! -d /opt/rustfs ]]; then
  exit 0
fi

podman rm --force --ignore rustfs >/dev/null
firewall-cmd --zone=libvirt --remove-port=9000/tcp || true
firewall-cmd --remove-port=9000/tcp || true
rm -rf /opt/rustfs
HOST
