#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Wait for StorageCluster CRD to be created"
timeout 5m bash -c '
  until oc get crd storageclusters.ocs.openshift.io &>/dev/null; do
    sleep 5
  done
'

echo "Deploying StorageCluster"
cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  resources: {}
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "${ODF_STORAGE_CLAIM}"
        storageClassName: "${ODF_STORAGE_CLASS}"
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
EOF

# Need to allow some time before checking if the StorageCluster is deployed
sleep 60

echo "⏳ Wait for StorageCluster to be deployed"
if ! oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster" \
    -n "$ODF_INSTALL_NAMESPACE" --for=condition='Available' --timeout="${SC_WAIT_TIMEOUT:-10m}"; then
    if [[ "${ODF_SC_AVAILABLE_FALLBACK:-}" != "true" ]]; then
        echo "ERROR: StorageCluster did not reach Available condition within ${SC_WAIT_TIMEOUT:-10m}"
        exit 1
    fi
    echo "StorageCluster Available condition not met; falling back to OSD readiness check (ODF_SC_AVAILABLE_FALLBACK=true)"
    # On HyperShift, OCSInitialization owner-ref resolution fails in the API server, which
    # prevents the Available condition from ever being set even when Ceph is healthy.
    # Wait for at least one OSD deployment to appear, then wait for all to be Available.
    echo "Waiting for rook-ceph-osd deployments to appear (up to 5m)..."
    timeout 5m bash -c '
      while true; do
        count=$(oc get deploy -n "'"$ODF_INSTALL_NAMESPACE"'" -l app=rook-ceph-osd --no-headers 2>/dev/null | wc -l | tr -d " ")
        if [[ "$count" -gt 0 ]]; then
          echo "Found ${count} OSD deployment(s)"
          break
        fi
        sleep 10
      done
    '
    oc wait deploy -l app=rook-ceph-osd -n "$ODF_INSTALL_NAMESPACE" \
        --for=condition=Available --timeout="${SC_WAIT_TIMEOUT:-10m}"
    echo "All OSD deployments are Available; storage is ready"
fi

echo "Remove is-default-class annotation from all the storage classes"
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-

echo "Make ocs-storagecluster-ceph-rbd the default storage class"
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

echo "ODF Operator is deployed successfully"
