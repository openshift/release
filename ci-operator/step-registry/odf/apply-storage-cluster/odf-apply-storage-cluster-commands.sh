#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Wait for StorageCluster CRD to be registered before applying the manifest.
oc wait crd storageclusters.ocs.openshift.io --for=condition=Established --timeout=5m

# Deploy StorageCluster (idempotent via oc apply).
{
    oc create -f - --dry-run=client -o yaml --save-config
} 0<<ocEOF | oc apply -f -
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
ocEOF

# OCS operator reconciliation is asynchronous; without this pause the oc wait
# below can race against the controller before it has registered the status conditions.
sleep 60

oc wait 'storagecluster.ocs.openshift.io/ocs-storagecluster' \
    -n "${ODF_INSTALL_NAMESPACE}" --for=condition='Available' --timeout="${ODF_STORAGE_CLUSTER_WAIT_TIMEOUT}"

# Remove is-default-class annotation from all storage classes, then promote
# ocs-storagecluster-ceph-rbd as the default storage class.
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

true
