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

# Close the firewall port even if removing the container fails.
firewall-cmd --zone=libvirt --remove-port=9000/tcp || true
if ! podman rm --force --ignore rustfs >/dev/null; then
  echo "Failed to remove the RustFS container." >&2
  exit 1
fi
rm -rf /opt/rustfs
HOST
