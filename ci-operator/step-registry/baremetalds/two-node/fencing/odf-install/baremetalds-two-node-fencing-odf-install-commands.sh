#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ODF_INSTALL_NAMESPACE=openshift-storage
ODF_OPERATOR_CHANNEL="${ODF_OPERATOR_CHANNEL:-stable-4.22}"
OSD_DISK_SERIAL="${OSD_DISK_SERIAL:-osd-disk}"
MON_DISK_SERIAL="${MON_DISK_SERIAL:-mon-disk}"
MON_DISK_SIZE="${MON_DISK_SIZE:-50G}"

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

NODES=($(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort))
if [[ ${#NODES[@]} -ne 2 ]]; then
  echo "ERROR: Expected exactly 2 master nodes, found ${#NODES[@]}"
  exit 1
fi
NODE_0="${NODES[0]}"
NODE_1="${NODES[1]}"

echo "Two-node cluster detected: ${NODE_0}, ${NODE_1}"

# ---------------------------------------------------------------------------
# Step 0: Configure VM disks on the hypervisor
#   - Shut down VMs
#   - Truncate mon disk (vdb) to desired size
#   - Add serial numbers to extra disks (vda=osd-disk, vdb=mon-disk)
#   - Start VMs and wait for nodes to be Ready
# ---------------------------------------------------------------------------
echo "--- Step 0: Configure VM disks on hypervisor ---"

if [[ ! -f "${SHARED_DIR}/packet-conf.sh" ]]; then
  echo "ERROR: packet-conf.sh not found, cannot SSH to hypervisor"
  exit 1
fi
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

VMS=("ostest_master_0" "ostest_master_1")
for vm in "${VMS[@]}"; do
  echo "[disk-setup] Configuring disks on ${vm}..."

  ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- \
      "${vm}" "${OSD_DISK_SERIAL}" "${MON_DISK_SERIAL}" "${MON_DISK_SIZE}" << 'HYPERVISOR_EOF'
set -euo pipefail

VM="$1"
OSD_SERIAL="$2"
MON_SERIAL="$3"
MON_SIZE="$4"

POOL_DIR="/opt/dev-scripts/pool"
OSD_TARGET="vda"
MON_TARGET="vdb"

echo "[hypervisor] Shutting down ${VM}..."
virsh -c qemu:///system shutdown "${VM}" 2>/dev/null || true

for i in {1..30}; do
  st=$(virsh -c qemu:///system domstate "${VM}" 2>/dev/null || true)
  [[ "${st}" == "shut off" ]] && break
  sleep 5
done

st=$(virsh -c qemu:///system domstate "${VM}" 2>/dev/null || true)
if [[ "${st}" != "shut off" ]]; then
  echo "[hypervisor] Force destroying ${VM}..."
  virsh -c qemu:///system destroy "${VM}" || true
fi
echo "[hypervisor] ${VM} is shut off"

mon_img="${POOL_DIR}/${VM}_${MON_TARGET}.img"
if [[ -f "${mon_img}" ]]; then
  truncate -s "${MON_SIZE}" "${mon_img}"
  echo "[hypervisor] Truncated ${mon_img} to ${MON_SIZE}"
else
  echo "[hypervisor] WARNING: ${mon_img} not found, skipping truncate"
fi

virt-xml "${VM}" --edit target="${OSD_TARGET}" --disk serial="${OSD_SERIAL}" 2>/dev/null || \
  echo "[hypervisor] WARNING: Could not set serial on ${VM} ${OSD_TARGET}"
virt-xml "${VM}" --edit target="${MON_TARGET}" --disk serial="${MON_SERIAL}" 2>/dev/null || \
  echo "[hypervisor] WARNING: Could not set serial on ${VM} ${MON_TARGET}"
echo "[hypervisor] ${VM}: ${OSD_TARGET}=${OSD_SERIAL}, ${MON_TARGET}=${MON_SERIAL}"

echo "[hypervisor] Starting ${VM}..."
virsh -c qemu:///system start "${VM}"
echo "[hypervisor] ${VM} started"
HYPERVISOR_EOF

  echo "Waiting for ${vm} to rejoin the cluster..."
  sleep 60
  oc wait nodes --all --for=condition=Ready --timeout=10m
  echo "All nodes Ready after ${vm} reconfiguration"
done

OSD_DISK_PATH="/dev/disk/by-id/virtio-${OSD_DISK_SERIAL}"
MON_DISK_PATH="/dev/disk/by-id/virtio-${MON_DISK_SERIAL}"
echo "OSD disk: ${OSD_DISK_PATH}, MON/DRBD disk: ${MON_DISK_PATH}"

# ---------------------------------------------------------------------------
# Step 1: Create manual StorageClass for local storage
# ---------------------------------------------------------------------------
echo "--- Step 1: Create manual StorageClass for local storage ---"
oc apply -f - <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
EOF

# ---------------------------------------------------------------------------
# Step 2: Create PVs for OSD disks on each node
# ---------------------------------------------------------------------------
echo "--- Step 2: Create PVs for OSD disks on each node ---"
oc apply -f - <<EOF
kind: PersistentVolume
apiVersion: v1
metadata:
  name: devicesetpv0
spec:
  storageClassName: local-storage
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Block
  local:
    path: ${OSD_DISK_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${NODE_0}
---
kind: PersistentVolume
apiVersion: v1
metadata:
  name: devicesetpv1
spec:
  storageClassName: local-storage
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Block
  local:
    path: ${OSD_DISK_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${NODE_1}
EOF

# ---------------------------------------------------------------------------
# Step 3: Install ODF operator
# ---------------------------------------------------------------------------
echo "--- Step 3: Install ODF operator ---"
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ODF_INSTALL_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha2
kind: OperatorGroup
metadata:
  name: openshift-storage-og
  namespace: ${ODF_INSTALL_NAMESPACE}
spec:
  targetNamespaces:
  - ${ODF_INSTALL_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: ${ODF_INSTALL_NAMESPACE}
spec:
  channel: "${ODF_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# ---------------------------------------------------------------------------
# Step 4: Wait for ODF CSV
# ---------------------------------------------------------------------------
echo "--- Step 4: Wait for ODF CSV ---"
RETRIES=90
for ((i=1; i <= RETRIES; i++)); do
    CSV=$(oc -n "${ODF_INSTALL_NAMESPACE}" get subscription odf-operator \
        -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [[ -n "$CSV" ]]; then
        PHASE=$(oc -n "${ODF_INSTALL_NAMESPACE}" get csv "$CSV" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$PHASE" == "Succeeded" ]]; then
            echo "CSV ${CSV} ready"
            break
        fi
        echo "Try ${i}/${RETRIES}: CSV ${CSV} phase=${PHASE}"
    else
        echo "Try ${i}/${RETRIES}: Waiting for CSV..."
    fi
    sleep 10
done

if [[ -z "${CSV:-}" ]] || [[ "$(oc -n "${ODF_INSTALL_NAMESPACE}" get csv "${CSV}" \
    -o jsonpath='{.status.phase}' 2>/dev/null)" != "Succeeded" ]]; then
    echo "ERROR: ODF CSV did not reach Succeeded phase"
    oc -n "${ODF_INSTALL_NAMESPACE}" get subscription odf-operator -o yaml
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: DRBD floating monitor setup
# ---------------------------------------------------------------------------
echo "--- Step 5: DRBD floating monitor setup ---"
echo "Retrieving drbd-setup script from ConfigMap..."
for ((i=1; i <= 60; i++)); do
    if oc get configmap rook-ceph-drbd-setup-script -n "${ODF_INSTALL_NAMESPACE}" &>/dev/null; then
        echo "Found drbd-setup ConfigMap"
        break
    fi
    echo "Try ${i}/60: Waiting for drbd-setup ConfigMap..."
    sleep 10
done

if ! oc get configmap rook-ceph-drbd-setup-script -n "${ODF_INSTALL_NAMESPACE}" &>/dev/null; then
    echo "ERROR: drbd-setup ConfigMap not found after 10 minutes"
    exit 1
fi

oc get configmap rook-ceph-drbd-setup-script -n "${ODF_INSTALL_NAMESPACE}" \
    -o jsonpath='{.data.script}' | base64 -d > /tmp/drbd-setup
chmod +x /tmp/drbd-setup

# Workaround DFBUGS-8896: add --authfile so podman can pull the DRBD image
sed -i 's|podman run --rm --privileged|podman run --rm --privileged --authfile /var/lib/kubelet/config.json|g' /tmp/drbd-setup

# Relax ROTA check: virtual disks in libvirt report ROTA=1
if grep -q 'non-rotational' /tmp/drbd-setup; then
  sed -i '/non-rotational/s/die /echo /' /tmp/drbd-setup
  echo "Patched ROTA check in drbd-setup"
fi

echo "Running drbd-setup with mon disk ${MON_DISK_PATH}..."
/tmp/drbd-setup -d "${MON_DISK_PATH}"

# ---------------------------------------------------------------------------
# Step 6: Label nodes for ODF storage
# ---------------------------------------------------------------------------
echo "--- Step 6: Label nodes for ODF storage ---"
oc label nodes "${NODE_0}" "${NODE_1}" \
    cluster.ocs.openshift.io/openshift-storage="" --overwrite

# ---------------------------------------------------------------------------
# Step 7: Wait for StorageCluster CRD
# ---------------------------------------------------------------------------
echo "--- Step 7: Wait for StorageCluster CRD ---"
timeout 30m bash -c '
  until oc get crd storageclusters.ocs.openshift.io &>/dev/null; do
    sleep 5
  done
'

# ---------------------------------------------------------------------------
# Step 8: Create 2-node StorageCluster
# ---------------------------------------------------------------------------
echo "--- Step 8: Create 2-node StorageCluster ---"
oc apply -f - <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: ${ODF_INSTALL_NAMESPACE}
spec:
  encryption:
    keyRotation:
      schedule: "@weekly"
  flexibleScaling: true
  managedResources:
    cephBlockPools:
      poolSpec:
        application: ""
        erasureCoded:
          codingChunks: 0
          dataChunks: 0
        replicated:
          size: 2
    cephCluster:
      cephConfig:
        global:
          osd_pool_default_size: "2"
          osd_heartbeat_grace: "20"
          mon_osd_down_out_interval: "120"
          mon_osd_report_timeout: "120"
    cephFilesystems:
      dataPoolSpec:
        application: ""
        erasureCoded:
          codingChunks: 0
          dataChunks: 0
        replicated:
          size: 2
      metadataPoolSpec:
        application: ""
        erasureCoded:
          codingChunks: 0
          dataChunks: 0
        replicated:
          size: 2
    cephObjectStoreUsers:
      reconcileStrategy: ignore
    cephObjectStores:
      reconcileStrategy: ignore
  monDataDirHostPath: /var/lib/rook
  multiCloudGateway:
    reconcileStrategy: ignore
  resources:
    crashcollector:
      requests:
        cpu: 10m
        memory: 50Mi
    exporter:
      requests:
        cpu: 10m
        memory: 50Mi
    log-collector:
      requests:
        cpu: 10m
        memory: 50Mi
    mds:
      requests:
        cpu: 100m
        memory: 2Gi
    mgr:
      requests:
        cpu: 100m
        memory: 250Mi
    mgr-sidecar:
      requests:
        cpu: 10m
        memory: 75Mi
    mon:
      requests:
        cpu: 100m
        memory: 250Mi
    ocs-metrics-exporter:
      requests:
        cpu: 50m
        memory: 100Mi
    ocs-provider-server:
      requests:
        cpu: 10m
        memory: 100Mi
    odf-blackbox-exporter:
      requests:
        cpu: 10m
        memory: 75Mi
    rgw:
      requests:
        cpu: 100m
        memory: 250Mi
    rook-ceph-tools:
      requests:
        cpu: 10m
        memory: 100Mi
  storageDeviceSets:
    - config: {}
      count: 1
      dataPVCTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 1
          storageClassName: local-storage
          volumeMode: Block
      encrypted: false
      name: ocs-deviceset
      replica: 2
      resources:
        requests:
          cpu: 350m
          memory: 2Gi
        limits:
          cpu: 700m
          memory: 4Gi
EOF

# ---------------------------------------------------------------------------
# Step 9: Wait for StorageCluster
# ---------------------------------------------------------------------------
echo "--- Step 9: Wait for StorageCluster ---"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster" \
    -n "${ODF_INSTALL_NAMESPACE}" --for=condition='Available' --timeout='30m'

echo "ODF 2-node installation complete"
oc get sc
