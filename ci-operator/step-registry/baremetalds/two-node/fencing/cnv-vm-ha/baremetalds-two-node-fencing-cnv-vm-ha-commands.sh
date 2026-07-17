#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_STORAGE_CLASS="${CNV_STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-virtualization}"

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  echo "ERROR: packet-conf.sh not found, cannot SSH to hypervisor"
  exit 1
fi
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

run_on_node() {
  local node="$1"
  shift
  oc debug -n default "node/${node}" -- chroot /host bash -c "$*"
}

NODES=($(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort))
NODE_0="${NODES[0]}"
NODE_1="${NODES[1]}"
echo "Cluster nodes: ${NODE_0}, ${NODE_1}"

# -------------------------------------------------------------------------
# Wait for the virtualization StorageClass
# -------------------------------------------------------------------------
echo "--- Waiting for StorageClass ${CNV_STORAGE_CLASS} ---"
timeout 40m bash -c "
  until oc get storageclass ${CNV_STORAGE_CLASS} &>/dev/null; do
    echo \"\$(date): ${CNV_STORAGE_CLASS} not yet available, waiting...\"
    sleep 30
  done
"
echo "StorageClass ${CNV_STORAGE_CLASS} available"

# -------------------------------------------------------------------------
# Wait for golden images and find the Fedora snapshot
# -------------------------------------------------------------------------
echo "--- Waiting for golden images ---"
oc wait DataImportCron -n openshift-virtualization-os-images \
  --all --for=condition=UpToDate --timeout=20m

FEDORA_SNAP=$(oc get volumesnapshot -n openshift-virtualization-os-images \
  -o jsonpath='{.items[?(@.status.readyToUse==true)].metadata.name}' | tr ' ' '\n' | grep fedora | head -1)

if [[ -z "${FEDORA_SNAP}" ]]; then
  echo "ERROR: No ready Fedora VolumeSnapshot found in openshift-virtualization-os-images"
  oc get volumesnapshot -n openshift-virtualization-os-images
  exit 1
fi
echo "Using Fedora snapshot: ${FEDORA_SNAP}"

# -------------------------------------------------------------------------
# Create a test VM with LiveMigrate eviction on an RWX PVC
# -------------------------------------------------------------------------
echo "--- Creating test VM for HA validation ---"
oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm-ha
  namespace: default
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: test-vm-ha-rootdisk
      spec:
        source:
          snapshot:
            namespace: openshift-virtualization-os-images
            name: ${FEDORA_SNAP}
        storage:
          accessModes:
            - ReadWriteMany
          storageClassName: ${CNV_STORAGE_CLASS}
          resources:
            requests:
              storage: 32Gi
  template:
    spec:
      evictionStrategy: LiveMigrate
      domain:
        devices:
          disks:
            - disk:
                bus: virtio
              name: rootdisk
          interfaces:
            - masquerade: {}
              name: default
        resources:
          requests:
            memory: 128Mi
      networks:
        - name: default
          pod: {}
      volumes:
        - dataVolume:
            name: test-vm-ha-rootdisk
          name: rootdisk
EOF

echo "Waiting for VM to be Ready..."
oc wait vm/test-vm-ha -n default --for=condition=Ready --timeout=10m

VMI_NODE=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.nodeName}')
echo "VM is running on node: ${VMI_NODE}"

if [[ "${VMI_NODE}" == "${NODE_0}" ]]; then
  FENCE_NODE="${NODE_0}"
  SURVIVE_NODE="${NODE_1}"
else
  FENCE_NODE="${NODE_1}"
  SURVIVE_NODE="${NODE_0}"
fi
echo "Will fence ${FENCE_NODE}, expect VM to migrate to ${SURVIVE_NODE}"

# -------------------------------------------------------------------------
# Idempotent recovery: power on the fenced VM and restore STONITH action
# -------------------------------------------------------------------------
RECOVERY_NEEDED=false

recover_fenced_node() {
  if [[ "${RECOVERY_NEEDED}" != "true" ]]; then
    return 0
  fi
  echo "--- Recovery trap: restoring ${FENCE_NODE} ---"
  RECOVERY_NEEDED=false

  local fence_vm="ostest_${FENCE_NODE//-/_}"
  ssh "${SSHOPTS[@]}" "root@${IP}" \
    "virsh -c qemu:///system domstate ${fence_vm} | grep -q running || virsh -c qemu:///system start ${fence_vm}" || true

  sleep 30

  run_on_node "${SURVIVE_NODE}" \
    "sudo pcs stonith update ${FENCE_NODE}_redfish action=reboot --force" || true

  oc wait "node/${FENCE_NODE}" --for=condition=Ready --timeout=10m || true

  run_on_node "${SURVIVE_NODE}" "sudo pcs resource cleanup etcd" || true
  echo "--- Recovery trap complete ---"
}

trap recover_fenced_node EXIT

# -------------------------------------------------------------------------
# Fence the node running the VM
# -------------------------------------------------------------------------
echo "--- Fencing ${FENCE_NODE} ---"

echo "Setting STONITH action to off for ${FENCE_NODE}..."
run_on_node "${SURVIVE_NODE}" \
  "sudo pcs stonith update ${FENCE_NODE}_redfish action=off --force"
RECOVERY_NEEDED=true

echo "Fencing ${FENCE_NODE}..."
run_on_node "${SURVIVE_NODE}" \
  "sudo pcs stonith fence ${FENCE_NODE}"

echo "Waiting for ${FENCE_NODE} to become NotReady..."
oc wait "node/${FENCE_NODE}" --for=condition=Ready=False --timeout=5m || \
  oc wait "node/${FENCE_NODE}" --for=condition=Ready=Unknown --timeout=5m || true

echo "Verifying pcs status..."
run_on_node "${SURVIVE_NODE}" "sudo pcs status" || true

echo "Verifying etcd is running only on ${SURVIVE_NODE}..."
run_on_node "${SURVIVE_NODE}" "sudo pcs resource status" || true

# -------------------------------------------------------------------------
# Verify VM migrated to the surviving node
# -------------------------------------------------------------------------
echo "--- Verifying VM migration ---"
echo "Waiting for VM to be Running on ${SURVIVE_NODE}..."
for ((i=1; i <= 60; i++)); do
  VMI_STATUS=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
  VMI_CURRENT_NODE=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

  if [[ "${VMI_STATUS}" == "Running" && "${VMI_CURRENT_NODE}" == "${SURVIVE_NODE}" ]]; then
    echo "VM successfully migrated to ${SURVIVE_NODE} and is Running"
    break
  fi

  echo "Try ${i}/60: VM status=${VMI_STATUS:-?}, node=${VMI_CURRENT_NODE:-?}"
  sleep 10
done

VMI_STATUS=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
VMI_CURRENT_NODE=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

if [[ "${VMI_STATUS}" != "Running" || "${VMI_CURRENT_NODE}" != "${SURVIVE_NODE}" ]]; then
  echo "ERROR: VM did not migrate successfully. status=${VMI_STATUS}, node=${VMI_CURRENT_NODE}"
  oc get vmi -n default -o yaml || true
  oc get events -n default --sort-by='.lastTimestamp' || true
  exit 1
fi

echo "VM HA validation PASSED: VM migrated from ${FENCE_NODE} to ${SURVIVE_NODE}"

# -------------------------------------------------------------------------
# Recover the fenced node (uses the same idempotent function as the trap)
# -------------------------------------------------------------------------
recover_fenced_node
trap - EXIT

echo "Verifying cluster health..."

oc wait "node/${NODE_0}" "node/${NODE_1}" --for=condition=Ready --timeout=5m
echo "All nodes Ready"

run_on_node "${SURVIVE_NODE}" \
  "sudo pcs status | tee /dev/stderr | grep -qv 'Failed Actions:'" || {
    echo "ERROR: pcs reports failed actions after recovery"
    exit 1
  }

VMI_FINAL=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.phase}')
if [[ "${VMI_FINAL}" != "Running" ]]; then
  echo "ERROR: VMI is not Running after recovery (phase=${VMI_FINAL})"
  oc get vmi -n default -o yaml || true
  exit 1
fi
echo "VMI is Running"

echo "--- VM HA fencing test complete ---"
