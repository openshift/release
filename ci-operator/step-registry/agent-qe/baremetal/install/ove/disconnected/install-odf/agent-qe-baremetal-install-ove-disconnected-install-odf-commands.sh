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

echo "=== Waiting for all OSDs to come up ==="
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    OSD_UP=$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.osd.storeCount}' 2>/dev/null || echo "0")
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

echo "ODF installation completed successfully!"

echo "Available storage classes:"
oc get storageclass
