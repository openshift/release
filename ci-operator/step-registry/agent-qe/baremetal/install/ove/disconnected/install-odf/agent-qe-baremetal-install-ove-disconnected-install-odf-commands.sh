#!/bin/bash
set -euo pipefail

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
while [ $COUNTER -lt 300 ]; do
    CSV_NAME=$(oc get csv -n openshift-storage -l operators.coreos.com/odf-operator.openshift-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${CSV_NAME}" ]; then
        echo "CSV ${CSV_NAME} found"
        break
    fi
    sleep 5
    COUNTER=$((COUNTER + 5))
    echo "Waiting ${COUNTER}s for CSV to be created..."
done

if [ $COUNTER -ge 300 ]; then
    echo "ERROR: CSV was not created within timeout"
    oc get subscription -n openshift-storage
    oc get installplan -n openshift-storage
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

CEPH_IMAGE=""
for csv in $(oc get csv -n openshift-storage -o jsonpath='{.items[*].metadata.name}'); do
  CEPH_IMAGE=$(oc get csv "${csv}" -n openshift-storage -o json | \
    jq -r '[.spec.relatedImages[]? | select(.image | test("rhceph.*rhel"))] | first | .image // empty')
  if [[ -n "${CEPH_IMAGE}" ]]; then
    break
  fi
done
if [[ -z "${CEPH_IMAGE}" ]]; then
  echo "ERROR: Could not find Ceph image in any CSV in openshift-storage"
  echo "Available CSVs and their relatedImages:"
  oc get csv -n openshift-storage -o json | jq -r '.items[].spec.relatedImages[]?.name' | sort -u | head -20
  exit 1
fi
echo "Ceph image for BlueStore label cleanup: ${CEPH_IMAGE}"

echo "=== Wiping stale BlueStore labels from OSD block devices ==="
OSD_PVS=$(oc get pv -o json | jq -r \
  '.items[] | select(.spec.storageClassName == "'"${OSD_STORAGE_CLASS}"'") | .metadata.name')

if [[ -n "${OSD_PVS}" ]]; then
  IDX=0
  while IFS= read -r PV_NAME; do
    NODE=$(oc get pv "${PV_NAME}" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')
    PVC_NAME="bluestore-zap-${IDX}"
    echo "Cleaning BlueStore labels from PV ${PV_NAME} on ${NODE}..."

    cat <<PVCEOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: openshift-storage
spec:
  storageClassName: ${OSD_STORAGE_CLASS}
  volumeMode: Block
  volumeName: ${PV_NAME}
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
PVCEOF

    cat <<PODEOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${PVC_NAME}
  namespace: openshift-storage
spec:
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  containers:
  - name: zap
    image: ${CEPH_IMAGE}
    command:
    - bash
    - -c
    - |
      for attempt in 1 2 3 4 5; do
        LOC=\$(ceph-bluestore-tool show-label --dev /dev/osd-block 2>/dev/null | jq -r '.[].locations[0] // empty')
        if [[ -z "\${LOC}" ]]; then
          echo "Clean after \${attempt} attempt(s)"
          break
        fi
        OFFSET=\$(printf '%d' "\${LOC}")
        echo "Zeroing label at \${LOC} (byte \${OFFSET})..."
        dd if=/dev/zero of=/dev/osd-block bs=4096 count=256 seek=\$(( OFFSET / 4096 )) conv=fsync 2>/dev/null
      done
      wipefs -af /dev/osd-block 2>/dev/null || true
    securityContext:
      privileged: true
    volumeDevices:
    - name: data
      devicePath: /dev/osd-block
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
PODEOF

    oc wait --for=jsonpath='{.status.phase}'=Succeeded \
      "pod/${PVC_NAME}" -n openshift-storage --timeout=5m || \
      echo "WARNING: zap pod for PV ${PV_NAME} did not succeed"
    oc delete pod "${PVC_NAME}" -n openshift-storage --force --grace-period=0 2>/dev/null || true
    oc delete pvc "${PVC_NAME}" -n openshift-storage 2>/dev/null || true
    IDX=$((IDX + 1))
  done <<< "${OSD_PVS}"
  echo "BlueStore label cleanup complete"
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
oc wait StorageCluster/ocs-storagecluster -n openshift-storage --for=jsonpath='{.status.phase}'=Ready --timeout=1h

echo "ODF installation completed successfully!"

echo "Available storage classes:"
oc get storageclass
