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

sleep 120

echo "Current VM status after node degradation:"
virsh -c qemu:///system list --all

EOF

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc whoami || true
oc get nodes -o name || true

echo "Ensuring internal Image Registry is configured and Available on the surviving node..."

# 0) Wait up to ~15 minutes for the Image Registry CR to appear
for attempt in $(seq 1 30); do
  if oc get configs.imageregistry.operator.openshift.io/cluster >/dev/null 2>&1; then
    break
  fi
  echo "$(date) - waiting for Image Registry CR to appear (attempt ${attempt}/30)..."
  sleep 30
done

# If the operator was intentionally removed, skip politely
REG_STATE="$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.managementState}' 2>/dev/null || true)"
if [[ "${REG_STATE}" == "Removed" ]]; then
  echo "Image Registry managementState=Removed; skipping registry setup."
else
  # 1) Make it runnable on one node: Managed + emptyDir (idempotent)
  echo "Setting Image Registry to Managed + emptyDir (no-op if already configured)..."
  oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
    -p '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}' || true

  # 2) Ensure the pod (re)schedules now on the surviving master
  echo "Forcing image-registry rollout..."
  oc rollout restart deploy/image-registry -n openshift-image-registry || true

  echo "Waiting up to 12m for image-registry to become Available..."
  if ! oc rollout status deploy/image-registry -n openshift-image-registry --timeout=12m; then
    echo "WARNING: image-registry did not become Available within timeout; continuing anyway."
  fi

  # 3) Wait for internalRegistryHostname to be published (used by tests & OCM)
  echo "Waiting for image.config.openshift.io/cluster.status.internalRegistryHostname..."
  IRH=""
  for _ in $(seq 1 120); do
    IRH="$(oc get image.config.openshift.io/cluster -o jsonpath='{.status.internalRegistryHostname}' 2>/dev/null || true)"
    [[ -n "${IRH}" ]] && break
    sleep 5
  done
  [[ -n "${IRH}" ]] && echo "internalRegistryHostname=${IRH}" || echo "WARNING: internalRegistryHostname still empty."

  # 4) Nudge openshift-controller-manager to observe the hostname, then wait
  OCM_DEPLOY="$(oc -n openshift-controller-manager get deploy -o name 2>/dev/null | head -n1 || true)"
  if [[ -n "${OCM_DEPLOY}" ]]; then
    echo "Restarting ${OCM_DEPLOY} so it observes internalRegistryHostname..."
    oc rollout restart -n openshift-controller-manager "${OCM_DEPLOY}" || true
    oc rollout status  -n openshift-controller-manager "${OCM_DEPLOY}" --timeout=10m || true
  else
    echo "INFO: No deployment found in openshift-controller-manager namespace (skipping restart)."
  fi

  echo "Final image-registry deployment status:"
  oc get deploy/image-registry -n openshift-image-registry || true
fi
echo "Node degradation and pcs commands completed successfully"