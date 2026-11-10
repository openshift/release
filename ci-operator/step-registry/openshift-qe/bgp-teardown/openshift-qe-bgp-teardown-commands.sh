#!/bin/bash
set -o nounset
set -o pipefail

echo "=== BGP teardown: cleaning up bastion ==="

# ---------------------------------------------------------------------------
# Bastion SSH helpers (BM only — AWS bastion is dismantled by deprovision)
# ---------------------------------------------------------------------------
if [[ -f "${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key" ]]; then
  SSH_KEY="${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key"
  JUMPHOST=$(cat "${CLUSTER_PROFILE_DIR}/address")
  BASTION_HOST=$(cat "${CLUSTER_PROFILE_DIR}/bastion" 2>/dev/null || cat "${SHARED_DIR}/bastion")
  SSH_USER="root"
  SSH_ARGS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
else
  echo "No BM bastion credentials found — skipping cleanup"
  exit 0
fi

bastion_ssh() {
  ssh ${SSH_ARGS} \
    -o ProxyCommand="ssh ${SSH_ARGS} -W %h:%p ${SSH_USER}@${JUMPHOST}" \
    "${SSH_USER}@${BASTION_HOST}" "$@"
}

# ---------------------------------------------------------------------------
# Cleanup FRR container, dummy interfaces, and stale BGP routes
# ---------------------------------------------------------------------------
echo "=== Stopping and removing FRR container ==="
bastion_ssh bash -s <<'EOF' || true
set -o pipefail

echo "[CLEANUP] Stopping FRR container..."
podman stop frr >/dev/null 2>&1 || true
sleep 5
podman rm -f frr >/dev/null 2>&1 || true

echo "[CLEANUP] Removing dummy interfaces..."
ip -o link show | awk -F': ' '{print $2}' | grep '^dummy' | while read -r iface; do
  ip link set "${iface}" down 2>/dev/null || true
  ip link delete "${iface}" 2>/dev/null || true
  echo "[CLEANUP] Removed interface ${iface}"
done

echo "[CLEANUP] Removing stale BGP routes..."
ip route show proto bgp | grep '^40\.' | awk '{print $1}' | while read -r route; do
  ip route del "${route}" 2>/dev/null || true
done

# Run the EVPN VRF cleanup script if it was left on the bastion by bgp-setup-evpn.
# This tears down VRF namespaces, VXLAN tunnels, and VNI configs.
# Must run before work directories are removed.
for cleanup_dir in /root/evpn /tmp; do
  if [[ -x "${cleanup_dir}/cleanup_external_frr_vrf.sh" ]]; then
    echo "[CLEANUP] Running ${cleanup_dir}/cleanup_external_frr_vrf.sh"
    cd "${cleanup_dir}"
    ./cleanup_external_frr_vrf.sh 72 || true
    break
  fi
done

echo "[CLEANUP] Removing work directories..."
for workdir in /root/evpn /root/udn-bgp /tmp/frr-k8s; do
  if [[ -d "${workdir}" ]]; then
    echo "[CLEANUP] Removing ${workdir}"
    rm -rf "${workdir}"
  fi
done

echo "[CLEANUP] Bastion cleanup complete."
EOF

echo "=== BGP teardown finished ==="
