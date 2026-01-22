#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "${CLUSTER_PROFILE_DIR}/address")

echo "[INFO] Starting cleanup on bastion: ${bastion}"

# shellcheck disable=SC2087
if [ "${NETWORK_WORKLOAD}" == "netperf-external" ]; then
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
EOF
fi

# shellcheck disable=SC2087
if [ "${NETWORK_WORKLOAD}" == "udn-bgp" ]; then
    ssh ${SSH_ARGS} root@"${bastion}" bash -s <<EOF
        rm -rf ~/frr-k8s
	# Removing frr routers
	podman stop frr >/dev/null 2>&1 || true
        sleep 5
	podman rm -f frr >/dev/null 2>&1 || true
        sleep 5
	# workload already deleted dummy interfaces and imported routes. We are manually trying to cleanup for safer side
	echo "Deleting stale dummy interfaces and Routes"
	ip -o link show | awk -F': ' '{print \$2}' | grep '^dummy' | xargs -I {} sudo ip link delete {}
	ip route show proto bgp | grep '^40\.' | awk '{print \$1}' | xargs -I {} ip route del {}
EOF
fi

echo "[CLEANUP] Done."
