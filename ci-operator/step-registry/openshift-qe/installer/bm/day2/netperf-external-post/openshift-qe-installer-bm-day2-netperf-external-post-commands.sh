#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "${CLUSTER_PROFILE_DIR}/address")

echo "[INFO] Starting cleanup on bastion: ${bastion}"

# shellcheck disable=SC2087
ssh -q ${SSH_ARGS} root@"${bastion}" bash -s <<'EOF'
set -euo pipefail

echo "[CLEANUP] Stopping netserver container..."
podman ps --filter "ancestor=quay.io/cloud-bulldozer/k8s-netperf:latest" -q | xargs -r podman stop || true
podman ps -a --filter "ancestor=quay.io/cloud-bulldozer/k8s-netperf:latest" -q | xargs -r podman rm -f || true

echo "[CLEANUP] Removing dummy0 interface if it exists..."
if ip link show dummy0 &>/dev/null; then
    ip link set dummy0 down || true
    ip link delete dummy0 type dummy || true
    echo "[CLEANUP] dummy0 interface removed."
else
    echo "[CLEANUP] dummy0 interface not found; skipping."
fi

echo "[CLEANUP] Done."
EOF

