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

mapfile -t NODES < <(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
NODE_0="${NODES[0]}"
NODE_1="${NODES[1]}"
echo "Cluster nodes: ${NODE_0}, ${NODE_1}"

NODE_0_IP=$(oc get node "${NODE_0}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
NODE_1_IP=$(oc get node "${NODE_1}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IPs: ${NODE_0}=${NODE_0_IP}, ${NODE_1}=${NODE_1_IP}"

declare -A NODE_IP
NODE_IP["${NODE_0}"]="${NODE_0_IP}"
NODE_IP["${NODE_1}"]="${NODE_1_IP}"

run_on_node() {
  local node="$1"
  shift
  local ip="${NODE_IP[${node}]}"
  ssh "${SSHOPTS[@]}" "root@${IP}" \
    "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${ip} 'sudo bash -c \"$*\"'"
}

collect_rbd_diagnostics() {
  local label="$1"
  echo ""
  echo "=== RBD/Ceph Diagnostics (${label}) ==="

  local toolbox
  toolbox=$(oc get pod -n openshift-storage -l app=rook-ceph-tools \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "${toolbox}" ]]; then
    echo "--- ceph -s ---"
    oc exec -n openshift-storage "${toolbox}" -- ceph -s 2>&1 || true

    echo "--- ceph osd tree ---"
    oc exec -n openshift-storage "${toolbox}" -- ceph osd tree 2>&1 || true

    echo "--- ceph osd blocklist ls ---"
    oc exec -n openshift-storage "${toolbox}" -- ceph osd blocklist ls 2>&1 || true

    echo "--- rbd ls ocs-storagecluster-cephblockpool ---"
    oc exec -n openshift-storage "${toolbox}" -- rbd ls ocs-storagecluster-cephblockpool 2>&1 || true

    local rbd_images
    rbd_images=$(oc exec -n openshift-storage "${toolbox}" -- \
        rbd ls ocs-storagecluster-cephblockpool 2>/dev/null || true)
    for img in ${rbd_images}; do
      echo "--- rbd status ocs-storagecluster-cephblockpool/${img} ---"
      oc exec -n openshift-storage "${toolbox}" -- \
          rbd status "ocs-storagecluster-cephblockpool/${img}" 2>&1 || true
    done
  else
    echo "WARNING: Ceph toolbox pod not found, skipping ceph/rbd diagnostics"
  fi

  echo "--- CephCluster health ---"
  oc get cephcluster -n openshift-storage \
      -o jsonpath='{.items[0].status.ceph}' 2>/dev/null || true
  echo ""

  echo "--- VolumeAttachments ---"
  oc get volumeattachment 2>&1 || true

  echo "--- All pods in openshift-storage ---"
  oc get pods -n openshift-storage -o wide 2>&1 || true

  echo "--- CSI attacher logs (last 50 lines per csi-rbdplugin container) ---"
  for pod in $(oc get pods -n openshift-storage \
      --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep csi-rbdplugin || true); do
    echo "--- ${pod} ---"
    oc logs "${pod}" -n openshift-storage -c csi-attacher --tail=50 2>&1 || true
  done

  echo "--- rook-ceph-operator logs (last 80 lines) ---"
  oc logs -n openshift-storage -l app=rook-ceph-operator --tail=80 2>&1 || true

  echo "=== End RBD/Ceph Diagnostics (${label}) ==="
  echo ""
}

# Echo the node names (from the arguments) where etcd is Started -- NOT
# Starting/FAILED/Stopped -- parsed from `pcs status` text on stdin. Only the
# etcd-clone block is considered, and names are compared literally so master-1
# does not match master-10.
parse_etcd_started_nodes() {
  # A single awk pass: isolate the etcd-clone block by indentation, collect the
  # nodes reported "Started" in either pcs rendering, and emit those that were
  # requested (in argument order). "Starting"/"FAILED"/"Stopped" are excluded
  # because none of them contain the literal word "Started".
  awk -v want="$*" '
    # Leading-whitespace width of a line, used to find the block boundary.
    function indent(line) { match(line, /^[[:space:]]*/); return RLENGTH }
    # Record a node, ignoring empties.
    function remember(node) { if (node != "") started[node] = 1 }

    BEGIN { n_want = split(want, want_list, " ") }

    # The etcd-clone header opens the block; remember how far it is indented.
    /Clone Set:[[:space:]]*etcd-clone/ { block_indent = indent($0); in_block = 1; next }

    # Any line indented no deeper than the header ends the block.
    in_block && indent($0) <= block_indent { in_block = 0 }

    in_block {
      # Form 1:  Started: [ master-0 master-1 ]
      if (match($0, /Started:[[:space:]]*\[[^]]*\]/)) {
        inside = substr($0, RSTART, RLENGTH)
        gsub(/^Started:[[:space:]]*\[[[:space:]]*|[[:space:]]*\]$/, "", inside)
        count = split(inside, list, /[[:space:]]+/)
        for (i = 1; i <= count; i++) remember(list[i])
      }
      # Form 2:  * etcd (...): Started master-0
      else if (match($0, /Started[[:space:]]+[^][:space:]]+/)) {
        token = substr($0, RSTART, RLENGTH)
        sub(/Started[[:space:]]+/, "", token)
        remember(token)
      }
    }

    # Emit the requested nodes that were Started, in argument order.
    END {
      for (i = 1; i <= n_want; i++)
        if (want_list[i] in started) print want_list[i]
    }
  '
}

# Node name(s) where etcd is Started, one per line, from the surviving node's
# `pcs status` (the single source of truth: it distinguishes Started from
# Starting/FAILED, which crm_resource --locate does not).
get_etcd_running_nodes() {
  local pcs
  pcs=$(run_on_node "${SURVIVE_NODE}" "pcs status" 2>/dev/null || true)
  printf '%s\n' "${pcs}" | parse_etcd_started_nodes "${NODE_0}" "${NODE_1}"
}

# Count etcd start-timeout signatures for node $1 in pacemaker journal text on
# stdin: controller ("Result of start operation ... Timed Out"), executor
# ("etcd_start_0 ... timed out"), and "giving up ... timeout" phrasings, each
# tied to a failure wording so a benign timeout: config value is not counted.
scan_etcd_start_timeouts() {
  local node="$1"
  grep -ciE "start operation for etcd on ${node}.*timed out|etcd_start_0.*timed out|giving up on etcd.*timeout" || true
}

# Echo the etcd start-timeout count for node $2 from pacemaker journal text on
# stdin, given the journal read status $1. A non-zero read echoes READ_FAILED so
# a lost journal is never mistaken for "no timeout".
etcd_start_timeout_count() {
  local rc="$1" node="$2"
  if [[ "${rc}" -ne 0 ]]; then
    echo "READ_FAILED"
    return 0
  fi
  { grep -i etcd || true; } | scan_etcd_start_timeouts "${node}"
}

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

echo "Setting ${CNV_STORAGE_CLASS} as default StorageClass..."
oc annotate storageclass "${CNV_STORAGE_CLASS}" \
    storageclass.kubernetes.io/is-default-class=true --overwrite

# -------------------------------------------------------------------------
# Wait for golden images and find the Fedora snapshot
# -------------------------------------------------------------------------
echo "--- Waiting for golden images ---"
if ! oc wait DataImportCron -n openshift-virtualization-os-images \
    --all --for=condition=UpToDate --timeout=40m; then
  echo "WARNING: Not all golden images are ready, dumping diagnostics..."
  echo ""
  echo "=== DataImportCron status ==="
  oc get dataimportcron -n openshift-virtualization-os-images -o wide || true
  echo ""
  echo "=== DataVolume status ==="
  oc get datavolume -n openshift-virtualization-os-images -o wide || true
  echo ""
  echo "=== PVC status ==="
  oc get pvc -n openshift-virtualization-os-images -o wide || true
  echo ""
  echo "=== VolumeSnapshot status ==="
  oc get volumesnapshot -n openshift-virtualization-os-images || true
  echo ""
  echo "=== CDI importer pods ==="
  oc get pods -n openshift-virtualization-os-images || true
  echo ""
  echo "=== Failed/pending importer pod logs (last 30 lines each) ==="
  for pod in $(oc get pods -n openshift-virtualization-os-images \
      --no-headers -o custom-columns=':metadata.name' 2>/dev/null || true); do
    echo "--- ${pod} ---"
    oc logs "${pod}" -n openshift-virtualization-os-images --tail=30 2>/dev/null || true
  done
  echo ""
  echo "=== Default StorageClass ==="
  oc get sc -o custom-columns='NAME:.metadata.name,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class' || true
  echo ""
  echo "=== Events in openshift-virtualization-os-images (last 20) ==="
  oc get events -n openshift-virtualization-os-images --sort-by='.lastTimestamp' | tail -20 || true
  echo ""
  echo "Checking if Fedora is available despite timeout..."
fi

FEDORA_SNAP=$(oc get volumesnapshot -n openshift-virtualization-os-images \
  -o jsonpath='{.items[?(@.status.readyToUse==true)].metadata.name}' | tr ' ' '\n' | grep fedora | head -1 || true)

if [[ -z "${FEDORA_SNAP}" ]]; then
  echo "ERROR: No ready Fedora VolumeSnapshot found in openshift-virtualization-os-images"
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
    "pcs stonith update ${FENCE_NODE}_redfish action=reboot --force" || true

  oc wait "node/${FENCE_NODE}" --for=condition=Ready --timeout=10m || true

  run_on_node "${SURVIVE_NODE}" "pcs resource cleanup etcd" || true
  echo "--- Recovery trap complete ---"
}

trap recover_fenced_node EXIT

# -------------------------------------------------------------------------
# Fence the node running the VM
# -------------------------------------------------------------------------
echo "--- Fencing ${FENCE_NODE} ---"

echo "Pre-fence pcs status:"
run_on_node "${SURVIVE_NODE}" "pcs status" || true

echo "Setting STONITH action to off for ${FENCE_NODE}..."
run_on_node "${SURVIVE_NODE}" \
  "pcs stonith update ${FENCE_NODE}_redfish action=off --force"
RECOVERY_NEEDED=true

echo "Fencing ${FENCE_NODE}..."
run_on_node "${SURVIVE_NODE}" \
  "pcs stonith fence ${FENCE_NODE}"

echo "Waiting for pcs to confirm etcd running on ${SURVIVE_NODE} and stopped on ${FENCE_NODE}..."
FENCE_CONFIRMED=false
for ((i=1; i <= 30; i++)); do
  RUNNING=$(get_etcd_running_nodes)
  ETCD_SURVIVE=$(echo "${RUNNING}" | grep -Fxc "${SURVIVE_NODE}" || true)
  ETCD_FENCED=$(echo "${RUNNING}" | grep -Fxc "${FENCE_NODE}" || true)
  if [[ "${ETCD_SURVIVE}" -ge 1 && "${ETCD_FENCED}" -eq 0 ]]; then
    echo "pcs confirms etcd running on ${SURVIVE_NODE} and stopped on ${FENCE_NODE}"
    run_on_node "${SURVIVE_NODE}" "pcs status" || true
    FENCE_CONFIRMED=true
    break
  fi
  echo "Try ${i}/30: etcd on ${SURVIVE_NODE}=${ETCD_SURVIVE}, on ${FENCE_NODE}=${ETCD_FENCED}, waiting..."
  sleep 10
done

if [[ "${FENCE_CONFIRMED}" != "true" ]]; then
  echo "ERROR: after fencing ${FENCE_NODE}, etcd never settled to running only on ${SURVIVE_NODE} within 30 attempts"
  run_on_node "${SURVIVE_NODE}" "pcs status" || true
  collect_rbd_diagnostics "fencing-confirmation-failure"
  exit 1
fi

echo "Waiting for ${FENCE_NODE} to become NotReady..."
oc wait "node/${FENCE_NODE}" --for=condition=Ready=False --timeout=5m || \
  oc wait "node/${FENCE_NODE}" --for=condition=Ready=Unknown --timeout=5m || true

echo "Verifying pcs status..."
run_on_node "${SURVIVE_NODE}" "pcs status" || true

echo "Verifying etcd is running only on ${SURVIVE_NODE}..."
run_on_node "${SURVIVE_NODE}" "pcs resource status" || true

collect_rbd_diagnostics "post-fencing"

# -------------------------------------------------------------------------
# Verify VM migrated to the surviving node
# -------------------------------------------------------------------------
echo "--- Verifying VM migration ---"
echo "Waiting up to 600s for VM to be Running on ${SURVIVE_NODE}..."
VM_MIGRATE_DEADLINE=$((SECONDS + 600))
while [[ ${SECONDS} -lt ${VM_MIGRATE_DEADLINE} ]]; do
  VMI_STATUS=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
  VMI_CURRENT_NODE=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

  if [[ "${VMI_STATUS}" == "Running" && "${VMI_CURRENT_NODE}" == "${SURVIVE_NODE}" ]]; then
    echo "VM successfully migrated to ${SURVIVE_NODE} and is Running"
    break
  fi

  if [[ -z "${VMI_STATUS}" && -z "${VMI_CURRENT_NODE}" ]]; then
    echo "API not reachable yet (stabilizing after fencing), retrying..."
  else
    echo "VM status=${VMI_STATUS:-?}, node=${VMI_CURRENT_NODE:-?}, retrying..."
  fi
  sleep 10
done

echo "Deadline reached, checking final state..."
VMI_STATUS=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
VMI_CURRENT_NODE=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

if [[ "${VMI_STATUS}" != "Running" || "${VMI_CURRENT_NODE}" != "${SURVIVE_NODE}" ]]; then
  echo "ERROR: VM did not migrate successfully. status=${VMI_STATUS}, node=${VMI_CURRENT_NODE}"
  collect_rbd_diagnostics "migration-failure"
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

run_on_node "${SURVIVE_NODE}" "pcs status" || true

# OCPBUGS-104449: after the fenced node reboots it rejoins etcd as a learner,
# running wipe_data_folder_for_learner() in the podman-etcd agent. With ODF
# mounted, a pre-fix bare `sync` there could hang and time out the etcd start.
echo ""
echo "=== Validating etcd learner-rejoin on ${FENCE_NODE} ==="

ETCD_REJOIN_TIMEOUT="${ETCD_REJOIN_TIMEOUT:-720}"

# Direct check for the hang: etcd must be Started on both nodes within the timeout.
echo "--- Waiting up to ${ETCD_REJOIN_TIMEOUT}s for etcd Started on both nodes ---"
ETCD_REJOINED=false
REJOIN_DEADLINE=$((SECONDS + ETCD_REJOIN_TIMEOUT))
while [[ ${SECONDS} -lt ${REJOIN_DEADLINE} ]]; do
  RUNNING=$(get_etcd_running_nodes)
  ETCD_ON_FENCE=$(echo "${RUNNING}" | grep -Fxc "${FENCE_NODE}" || true)
  ETCD_ON_SURVIVE=$(echo "${RUNNING}" | grep -Fxc "${SURVIVE_NODE}" || true)
  if [[ "${ETCD_ON_FENCE}" -ge 1 && "${ETCD_ON_SURVIVE}" -ge 1 ]]; then
    echo "etcd is running on both ${FENCE_NODE} and ${SURVIVE_NODE}"
    ETCD_REJOINED=true
    break
  fi
  echo "$(date): etcd on ${FENCE_NODE}=${ETCD_ON_FENCE}, ${SURVIVE_NODE}=${ETCD_ON_SURVIVE}; waiting..."
  sleep 20
done

# Scan the rejoining node's pacemaker journal for the etcd start-timeout
# signature. The read status is tracked so an SSH/journalctl failure yields
# READ_FAILED (treated as 0 here) rather than a false "no timeout".
JOURNAL_RC=0
PACE_RAW=$(run_on_node "${FENCE_NODE}" "journalctl -u pacemaker -b --no-pager" 2>/dev/null) || JOURNAL_RC=$?
PACE_ETCD=$(printf '%s\n' "${PACE_RAW}" | grep -i etcd || true)
TIMED_OUT=$(printf '%s\n' "${PACE_RAW}" | etcd_start_timeout_count "${JOURNAL_RC}" "${FENCE_NODE}")
if [[ "${TIMED_OUT}" == "READ_FAILED" ]]; then
  TIMED_OUT=0
  echo "WARNING: could not read pacemaker journal from ${FENCE_NODE} (rc=${JOURNAL_RC}); start-timeout scan skipped, relying on the etcd-Started check"
fi

if [[ "${ETCD_REJOINED}" != "true" || "${TIMED_OUT}" -ge 1 ]]; then
  echo "ERROR: etcd learner-rejoin validation FAILED on ${FENCE_NODE}:"
  [[ "${ETCD_REJOINED}" != "true" ]] && \
    echo "  - etcd did not return to Started on both nodes within ${ETCD_REJOIN_TIMEOUT}s"
  [[ "${TIMED_OUT}" -ge 1 ]] && \
    echo "  - found ${TIMED_OUT} etcd start timeout(s) (sync hang signature)"
  echo "--- pacemaker journal (etcd lines, tail) ---"
  printf '%s\n' "${PACE_ETCD}" | tail -40 || true
  run_on_node "${SURVIVE_NODE}" "pcs status" || true
  collect_rbd_diagnostics "etcd-learner-rejoin-failure"
  exit 1
fi

echo "=== etcd learner-rejoin completed with ODF present, no sync hang ==="
echo ""

VMI_FINAL=$(oc get vmi test-vm-ha -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
echo "VMI phase after recovery: ${VMI_FINAL:-unknown}"

echo "--- VM HA fencing test complete ---"
