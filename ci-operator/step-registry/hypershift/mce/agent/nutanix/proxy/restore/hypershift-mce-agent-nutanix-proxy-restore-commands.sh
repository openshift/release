#!/bin/bash

set -euo pipefail

original="${SHARED_DIR}/nutanix_squid_original.conf"
if [[ ! -s "${original}" ]]; then
  echo "No original Squid configuration was recorded; nothing to restore."
  exit 0
fi

source "${SHARED_DIR}/packet-conf.sh"
scp "${SSHOPTS[@]}" "${original}" "root@${IP}:/root/squid.conf"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s <<'EOF'
set -euo pipefail
sudo podman stop -t 120 external-squid || true
sudo podman run -d --rm --net host \
  --volume /root/squid.conf:/etc/squid/squid.conf \
  --name external-squid --dns 127.0.0.1 quay.io/openshifttest/squid-proxy:multiarch
for attempt in $(seq 1 10); do
  if sudo podman inspect --format '{{.State.Running}}' external-squid 2>/dev/null | grep -qx true; then
    break
  fi
  sleep 1
done
sudo podman inspect --format '{{.State.Running}}' external-squid | grep -qx true
EOF
rm -f "${original}"
