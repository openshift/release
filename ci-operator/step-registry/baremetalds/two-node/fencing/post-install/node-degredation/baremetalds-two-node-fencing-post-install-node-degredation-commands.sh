#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "baremetalds-two-node-fencing-post-install-node-degredation starting..."

# Check if DEGRADED_NODE is unset or empty
if [[ -z "${DEGRADED_NODE:-}" ]]; then
    echo "DEGRADED_NODE is not set, skipping node degradation"
    exit 0
fi

# Check if DEGRADED_NODE is set to "true"
if [[ "${DEGRADED_NODE}" != "true" ]]; then
    echo "DEGRADED_NODE is set to '${DEGRADED_NODE}', but not 'true', skipping node degradation"
    exit 0
fi

echo "DEGRADED_NODE is set to true, proceeding with node degradation..."

if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# SSH to the packet system and degrade the second node
echo "Connecting to packet system to degrade ostest_master_1..."

timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeo pipefail

set -o nounset
set -o errexit
set -o pipefail

echo "Connected to packet system, listing VMs..."
virsh -c qemu:///system list --all

echo "Looking for ostest_master_1 node..."
if virsh -c qemu:///system domstate ostest_master_1 >/dev/null 2>&1; then
    echo "Found ostest_master_1, proceeding with degradation..."

    #echo "Undefining ostest_master_1..."
    #virsh -c qemu:///system undefine ostest_master_1 --nvram|| true

    #echo "Destroying ostest_master_1..."
    #virsh -c qemu:///system destroy ostest_master_1 || true

    #echo "ostest_master_1 has been degraded (undefined and destroyed)"

    echo "Shutting down ostest_master_1..."
    virsh -c qemu:///system shutdown ostest_master_1 || true

    echo "Getting DHCP leases to find ostest_master_1 IP..."
    virsh -c qemu:///system net-dhcp-leases ostestbm

    # Extract ostest_master_0 IP address from DHCP leases
    MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm | grep master-0 | awk '{print $5}' | cut -d'/' -f1)

    if [[ -z "${MASTER0_IP}" ]]; then
        echo "ERROR: Could not find ostest_master_0 IP address in DHCP leases"
        exit 1
    fi

    echo "Found ostest_master_0 IP: ${MASTER0_IP}"
    echo "Connecting to ostest_master_0 to run pcs commands..."

    # SSH to ostest_master_0 and run pcs commands
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 core@"${MASTER0_IP}" << 'MASTER0_EOF'

    echo "Connected to ostest_master_0, running pcs commands..."

    echo "Running: sudo pcs resource status"
    sudo pcs resource status

    echo "Running: sudo pcs property set stonith-enabled=false"
    sudo pcs property set stonith-enabled=false

    echo "Running: sudo pcs resource cleanup etcd"
    sudo pcs resource cleanup etcd

    echo "Running: sudo pcs resource status (final check)"
    sudo pcs resource status

    echo "pcs commands completed successfully on ostest_master_0"

MASTER0_EOF

    echo "Successfully ran pcs commands on ostest_master_0"

else
    echo "WARNING: ostest_master_1 not found or not accessible"
    virsh -c qemu:///system list --all
    exit 1
fi

echo "Current VM status after node degradation:"
virsh -c qemu:///system list --all

EOF

echo "Ensuring internal Image Registry is Available on the surviving node..."

# Wait up to ~10 minutes for the Image Registry CR to appear
for i in {1..20}; do
  if oc get configs.imageregistry.operator.openshift.io/cluster >/dev/null 2>&1; then
    break
  fi
  echo "$(date) - waiting for Image Registry CR to appear..."
  sleep 30
done

echo "Patching Image Registry to use emptyDir storage (no-op if already set)..."
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  -p '{"spec":{"storage":{"emptyDir":{}}}}' || true

echo "Forcing a rollout to ensure the pod lands on the surviving control-plane node..."
oc rollout restart deploy/image-registry -n openshift-image-registry || true

echo "Waiting up to 10m for image-registry to become Available..."
if ! oc rollout status deploy/image-registry -n openshift-image-registry --timeout=10m; then
  echo "WARNING: image-registry did not become Available within timeout; continuing anyway."
fi

oc get deploy/image-registry -n openshift-image-registry || true


echo "Node degradation and pcs commands completed successfully"

