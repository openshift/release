#!/bin/bash
set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -z "${ODF_SUBSCRIPTION_CHANNEL}" ]]; then
    ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d '.' -f1,2)
    ODF_SUBSCRIPTION_CHANNEL="stable-${ocp_version}"
    echo "Auto-detected ODF subscription channel: ${ODF_SUBSCRIPTION_CHANNEL}"
fi

function gather_debug_info() {
    echo "============================================"
    echo "Gathering debug information to ARTIFACT_DIR"
    echo "============================================"

    if [ -z "${ARTIFACT_DIR:-}" ]; then
        echo "WARNING: ARTIFACT_DIR not set, skipping artifact collection"
        return
    fi

    local odf_artifacts="${ARTIFACT_DIR}/odf-gather"
    mkdir -p "${odf_artifacts}"/{pods,storagecluster,pod-logs,pvs,pvcs,storageclasses}

    echo "Collecting pods in openshift-storage namespace..."
    oc get pods -n openshift-storage -o wide > "${odf_artifacts}/pods/pods-list.txt" 2>&1 || true
    oc get pods -n openshift-storage -o yaml > "${odf_artifacts}/pods/pods-all.yaml" 2>&1 || true

    echo "Collecting StorageCluster resource..."
    oc get storagecluster ocs-storagecluster -n openshift-storage -o yaml > "${odf_artifacts}/storagecluster/ocs-storagecluster.yaml" 2>&1 || true
    oc describe storagecluster ocs-storagecluster -n openshift-storage > "${odf_artifacts}/storagecluster/ocs-storagecluster-describe.txt" 2>&1 || true

    echo "Collecting pod logs from openshift-storage namespace..."
    for pod in $(oc get pods -n openshift-storage -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo "  Collecting logs for pod: ${pod}"
        oc logs "${pod}" -n openshift-storage --all-containers=true > "${odf_artifacts}/pod-logs/${pod}.log" 2>&1 || true
        oc logs "${pod}" -n openshift-storage --all-containers=true --previous > "${odf_artifacts}/pod-logs/${pod}-previous.log" 2>&1 || true
    done

    echo "Collecting PersistentVolumes..."
    oc get pv -o wide > "${odf_artifacts}/pvs/pv-list.txt" 2>&1 || true
    oc get pv -o yaml > "${odf_artifacts}/pvs/pv-all.yaml" 2>&1 || true

    echo "Collecting PersistentVolumeClaims..."
    oc get pvc --all-namespaces -o wide > "${odf_artifacts}/pvcs/pvc-list-all-namespaces.txt" 2>&1 || true
    oc get pvc -n openshift-storage -o wide > "${odf_artifacts}/pvcs/pvc-list-openshift-storage.txt" 2>&1 || true
    oc get pvc -n openshift-storage -o yaml > "${odf_artifacts}/pvcs/pvc-openshift-storage.yaml" 2>&1 || true

    echo "Collecting StorageClasses..."
    oc get storageclass -o wide > "${odf_artifacts}/storageclasses/storageclass-list.txt" 2>&1 || true
    oc get storageclass -o yaml > "${odf_artifacts}/storageclasses/storageclass-all.yaml" 2>&1 || true

    echo "Collecting additional ODF resources..."
    oc get csv -n openshift-storage > "${odf_artifacts}/csv-list.txt" 2>&1 || true
    oc get subscription -n openshift-storage -o yaml > "${odf_artifacts}/subscription.yaml" 2>&1 || true
    oc get installplan -n openshift-storage -o yaml > "${odf_artifacts}/installplan.yaml" 2>&1 || true
    oc get cephcluster -n openshift-storage -o yaml > "${odf_artifacts}/cephcluster.yaml" 2>&1 || true
    oc get nodes -o wide > "${odf_artifacts}/nodes.txt" 2>&1 || true

    echo "Debug information collected in: ${odf_artifacts}"
}

trap 'gather_debug_info' ERR

echo "Labeling all nodes with cluster.ocs.openshift.io/openshift-storage..."
oc label nodes --all cluster.ocs.openshift.io/openshift-storage="" --overwrite

echo "Creating openshift-storage namespace..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
spec: {}
EOF

echo "Creating OperatorGroup for openshift-storage..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-og
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
  upgradeStrategy: Default
EOF

echo "Verifying CatalogSource ${CATALOGSOURCE_NAME} is ready..."
COUNTER=0
while [ $COUNTER -lt 300 ]; do
    CS_STATE=$(oc get catalogsource "${CATALOGSOURCE_NAME}" -n openshift-marketplace \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
    if [[ "${CS_STATE}" == "READY" ]]; then
        echo "CatalogSource ${CATALOGSOURCE_NAME} is READY"
        break
    fi
    sleep 10
    COUNTER=$((COUNTER + 10))
    echo "Waiting ${COUNTER}s for CatalogSource to be READY (current: ${CS_STATE:-unknown})..."
done
if [[ "${CS_STATE}" != "READY" ]]; then
    echo "WARNING: CatalogSource not READY after 300s, proceeding anyway..."
    echo "CatalogSource status:"
    oc get catalogsource "${CATALOGSOURCE_NAME}" -n openshift-marketplace -o yaml 2>/dev/null || true
    echo "CatalogSource pod:"
    oc get pods -n openshift-marketplace -l olm.catalogSource="${CATALOGSOURCE_NAME}" -o wide 2>/dev/null || true
fi

echo "Checking available ODF packages in catalog..."
oc get packagemanifest -n openshift-marketplace odf-operator 2>/dev/null && \
  echo "  Channels: $(oc get packagemanifest odf-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null)" || \
  echo "WARNING: odf-operator package not found in catalog"

echo "Creating Subscription for odf-operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: ${ODF_SUBSCRIPTION_CHANNEL}
  installPlanApproval: Automatic
  name: odf-operator
  source: ${CATALOGSOURCE_NAME}
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for odf-operator CSV to be created..."
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    CSV_NAME=$(oc get csv -n openshift-storage -l operators.coreos.com/odf-operator.openshift-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${CSV_NAME}" ]; then
        echo "CSV ${CSV_NAME} found"
        break
    fi
    sleep 10
    COUNTER=$((COUNTER + 10))
    if (( COUNTER % 60 == 0 )); then
        SUB_STATE=$(oc get subscription odf-operator -n openshift-storage -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
        SUB_CONDITIONS=$(oc get subscription odf-operator -n openshift-storage -o jsonpath='{range .status.conditions[*]}{.type}={.status}({.reason}): {.message}{"\n"}{end}' 2>/dev/null || echo "")
        IP_COUNT=$(oc get installplan -n openshift-storage --no-headers 2>/dev/null | wc -l)
        echo "  Subscription state: ${SUB_STATE}, InstallPlans: ${IP_COUNT}"
        if [[ -n "${SUB_CONDITIONS}" ]]; then
            echo "  Conditions: ${SUB_CONDITIONS}"
        fi
    else
        echo "Waiting ${COUNTER}s for CSV to be created..."
    fi
done

if [ $COUNTER -ge 600 ]; then
    echo "ERROR: CSV was not created within 600s"
    echo "=== Subscription details ==="
    oc get subscription odf-operator -n openshift-storage -o yaml 2>/dev/null || true
    echo "=== InstallPlans ==="
    oc get installplan -n openshift-storage -o wide 2>/dev/null || echo "No InstallPlans found"
    echo "=== CSVs ==="
    oc get csv -n openshift-storage 2>/dev/null || echo "No CSVs found"
    echo "=== CatalogSource status ==="
    oc get catalogsource "${CATALOGSOURCE_NAME}" -n openshift-marketplace -o jsonpath='{.status}' 2>/dev/null | jq . 2>/dev/null || true
    echo "=== CatalogSource pod ==="
    oc get pods -n openshift-marketplace -l olm.catalogSource="${CATALOGSOURCE_NAME}" -o wide 2>/dev/null || true
    oc logs -n openshift-marketplace -l olm.catalogSource="${CATALOGSOURCE_NAME}" --tail=30 2>/dev/null || true
    echo "=== OLM operator pod logs (last 30 lines) ==="
    oc logs -n openshift-operator-lifecycle-manager -l app=catalog-operator --tail=30 2>/dev/null || true
    exit 1
fi

echo "Waiting for odf-operator CSV to be in Succeeded phase..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv "${CSV_NAME}" \
  -n openshift-storage \
  --timeout=600s

echo "Waiting for StorageCluster CRD to be created..."
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    if oc get crd storageclusters.ocs.openshift.io &>/dev/null; then
        echo "StorageCluster CRD found"
        break
    fi
    sleep 5
    COUNTER=$((COUNTER + 5))
    echo "Waiting ${COUNTER}s for StorageCluster CRD..."
done

if [ $COUNTER -ge 600 ]; then
    echo "ERROR: StorageCluster CRD was not created within timeout"
    echo "Available CRDs related to OCS/ODF:"
    oc get crd | grep -E "ocs|odf|ceph|rook" || echo "No OCS/ODF CRDs found"
    echo "CSV status:"
    oc get csv -n openshift-storage
    exit 1
fi

echo "Waiting for StorageCluster CRD to be established..."
oc wait crd storageclusters.ocs.openshift.io --for=condition=established --timeout=5m

echo "=== Wiping stale signatures from OSD devices ==="
# Wipe OSD devices directly on the host via oc debug node. This is the only
# reliable approach because:
# 1. Container-based wipefs does NOT update the host udev database
# 2. BlueStore labels in Ceph Tentacle (v20.x) are stored at MULTIPLE offsets
#    (e.g., 1 GiB, 10 GiB, 100 GiB into the device), making targeted zeroing fragile
# 3. Only host-level wipefs/udevadm ensures Rook OSD prepare sees a clean device

OSD_PV_JSON=$(oc get pv -o json | jq -c \
  '[.items[] | select(.spec.storageClassName == "'"${OSD_STORAGE_CLASS}"'") |
    {name: .metadata.name,
     node: .metadata.labels["kubernetes.io/hostname"],
     path: .spec.local.path}]')
OSD_PV_COUNT=$(echo "${OSD_PV_JSON}" | jq 'length')
echo "Found ${OSD_PV_COUNT} OSD PVs"

if [[ "${OSD_PV_COUNT}" -gt 0 ]]; then
  IDX=0
  for row in $(echo "${OSD_PV_JSON}" | jq -r '.[] | @base64'); do
    PV_NAME=$(echo "${row}" | base64 -d | jq -r '.name')
    NODE=$(echo "${row}" | base64 -d | jq -r '.node')
    DEV_PATH=$(echo "${row}" | base64 -d | jq -r '.path')
    echo "  Wiping ${DEV_PATH} on ${NODE} (PV: ${PV_NAME})..."

    oc debug "node/${NODE}" --namespace=default -- chroot /host bash -c "
      DEVLINK='${DEV_PATH}'
      REALDEV=\$(readlink -f \${DEVLINK} 2>/dev/null || echo \${DEVLINK})
      DEVSIZE=\$(blockdev --getsize64 \${REALDEV} 2>/dev/null || echo 0)
      DEVMB=\$(( DEVSIZE / 1048576 ))
      echo \"=== Wiping \${REALDEV} (via \${DEVLINK}), size \${DEVMB} MiB ===\"
      wipefs -af \${REALDEV} 2>&1 || true
      sgdisk --zap-all \${REALDEV} 2>&1 || true
      # Zero first 100 MiB (covers filesystem superblocks + BlueStore at offset 0)
      dd if=/dev/zero of=\${REALDEV} bs=1M count=100 conv=fsync 2>/dev/null
      # Zero 2 MiB at every GiB boundary from 1-11 GiB (covers label at ~1 GiB, ~10 GiB)
      for GB in 1 2 3 4 5 6 7 8 9 10 11; do
        dd if=/dev/zero of=\${REALDEV} bs=1M count=2 seek=\$(( GB * 1024 )) conv=fsync 2>/dev/null
      done
      # Zero 2 MiB at 25/50/75/100 GiB boundaries (covers label at ~100 GiB)
      for GB in 25 50 75 100; do
        SEEKMB=\$(( GB * 1024 ))
        if [ \${SEEKMB} -lt \${DEVMB} ]; then
          dd if=/dev/zero of=\${REALDEV} bs=1M count=2 seek=\${SEEKMB} conv=fsync 2>/dev/null
        fi
      done
      # Zero last 10 MiB
      if [ \${DEVMB} -gt 10 ]; then
        dd if=/dev/zero of=\${REALDEV} bs=1M count=10 seek=\$(( DEVMB - 10 )) conv=fsync 2>/dev/null || true
      fi
      partprobe \${REALDEV} 2>/dev/null || true
      udevadm trigger --subsystem-match=block --action=change \${REALDEV} 2>/dev/null || true
      udevadm settle --timeout=30 2>/dev/null || true
      echo \"=== Verifying ===\"
      lsblk \${REALDEV} --nodeps --pairs --output FSTYPE 2>&1
      blkid \${REALDEV} 2>&1 || echo 'blkid: clean (no signatures)'
      echo \"Wipe complete for \${REALDEV}\"
    " 2>&1 || echo "  WARNING: oc debug wipe failed for ${NODE}:${DEV_PATH}"
    IDX=$((IDX + 1))
  done
  echo "Device wipe complete (${IDX} devices processed)"
else
  echo "  No OSD PVs found — skipping wipe"
fi

echo "Creating StorageCluster..."
cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  managedResources:
    cephFilesystems: {}
    cephObjectStores: {}
  monPVCTemplate:
    spec:
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 50Gi
      storageClassName: ${MON_STORAGE_CLASS}
  multiCloudGateway:
    reconcileStrategy: ignore
  storageDeviceSets:
    - name: osd-deviceset
      count: 1
      dataPVCTemplate:
        spec:
          storageClassName: ${OSD_STORAGE_CLASS}
          volumeMode: Block
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 100Gi
      replica: 3
EOF

echo "Wait for StorageCluster to become Ready"
if ! oc wait StorageCluster/ocs-storagecluster -n openshift-storage --for=jsonpath='{.status.phase}'=Ready --timeout=1h; then
    echo "ERROR: StorageCluster did not become Ready within 1h"
    echo "=== Gathering debug info ==="
    oc get cephcluster -n openshift-storage -o yaml 2>/dev/null || true
    oc get pods -n openshift-storage -o wide 2>/dev/null || true
    exit 1
fi

echo "=== Waiting for all OSDs to come up ==="
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    OSD_UP=$(oc get pods -n openshift-storage -l app=rook-ceph-osd --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [[ "${OSD_UP}" -ge 3 ]]; then
        echo "All ${OSD_UP} OSDs are up"
        break
    fi
    sleep 15
    COUNTER=$((COUNTER + 15))
    echo "Waiting ${COUNTER}s for OSDs (${OSD_UP:-0}/3 up)..."
done
if [[ "${OSD_UP}" -lt 3 ]]; then
    echo "WARNING: Only ${OSD_UP}/3 OSDs up after timeout"
    oc get cephcluster -n openshift-storage -o yaml || true
fi

echo "=== Waiting for Ceph health to stabilize ==="
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    HEALTH=$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo "")
    if [[ "${HEALTH}" == "HEALTH_OK" ]]; then
        echo "Ceph cluster is HEALTH_OK"
        break
    fi
    sleep 15
    COUNTER=$((COUNTER + 15))
    DETAILS=$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.details}' 2>/dev/null || echo "")
    echo "Waiting ${COUNTER}s for Ceph health (current: ${HEALTH:-unknown})..."
    if [[ -n "${DETAILS}" ]]; then
        echo "  Details: ${DETAILS}"
    fi
done
if [[ "${HEALTH}" != "HEALTH_OK" ]]; then
    echo "WARNING: Ceph health is ${HEALTH} (not HEALTH_OK) — proceeding anyway"
    echo "Ceph status:"
    oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph}' | jq . 2>/dev/null || true
fi

echo "=== Verifying CephFS provisioner is ready ==="
COUNTER=0
while [ $COUNTER -lt 300 ]; do
    MDS_READY=$(oc get pods -n openshift-storage -l app=rook-ceph-mds --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [[ "${MDS_READY}" -ge 2 ]]; then
        echo "CephFS MDS pods ready (${MDS_READY} running)"
        break
    fi
    sleep 10
    COUNTER=$((COUNTER + 10))
    echo "Waiting ${COUNTER}s for CephFS MDS pods (${MDS_READY:-0} running, need 2)..."
done

echo "Verifying CephFS PVC provisioning works..."
cat <<TESTEOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-cephfs-test
  namespace: openshift-storage
spec:
  storageClassName: ocs-storagecluster-cephfs
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  volumeMode: Filesystem
TESTEOF
if oc wait pvc odf-cephfs-test -n openshift-storage --for=jsonpath='{.status.phase}'=Bound --timeout=120s 2>/dev/null; then
    echo "CephFS provisioning verified"
else
    echo "WARNING: CephFS test PVC did not bind within 120s"
    oc get pvc odf-cephfs-test -n openshift-storage -o yaml 2>/dev/null || true
    oc get events -n openshift-storage --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
fi
oc delete pvc odf-cephfs-test -n openshift-storage --wait=false 2>/dev/null || true

echo "ODF installation completed successfully!"

echo "Available storage classes:"
oc get storageclass
