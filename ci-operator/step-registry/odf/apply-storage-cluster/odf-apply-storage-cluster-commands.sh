#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

DumpStorageCluster() {
    : "--- StorageCluster dump (failure diagnostics) ---"
    oc get storagecluster ocs-storagecluster -n "${ODF__INSTALL_NAMESPACE}" -o yaml || true
    oc describe storagecluster ocs-storagecluster -n "${ODF__INSTALL_NAMESPACE}" || true
    true
}
trap DumpStorageCluster ERR INT TERM

# Wait for StorageCluster CRD to appear before applying the manifest (ocs-operator installs it after odf-operator),
# then for Established. --for=condition=Established alone fails immediately with
# NotFound if the CRD does not exist yet.
oc wait --for=create crd/storageclusters.ocs.openshift.io --timeout=5m 1>/dev/null
oc wait crd/storageclusters.ocs.openshift.io --for=condition=Established --timeout=5m 1>/dev/null

# Deploy StorageCluster (idempotent via oc apply).
{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg installNamespace "${ODF__INSTALL_NAMESPACE}" \
        --arg storageClass "${ODF__STORAGE_CLASS}" \
        --arg storageClaim "${ODF__STORAGE_CLAIM}" \
        '
            .metadata.namespace = $installNamespace |
            .spec.storageDeviceSets[0].dataPVCTemplate.spec.resources.requests.storage = $storageClaim |
            .spec.storageDeviceSets[0].dataPVCTemplate.spec.storageClassName = $storageClass
        '
} 0<<'ocEOF' | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: placeholder
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
            storage: placeholder
        storageClassName: placeholder
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
ocEOF

# Block until the OCS operator has started reconciling (Progressing=True), which
# guarantees status conditions are present before we poll for Available.
oc wait 'storagecluster.ocs.openshift.io/ocs-storagecluster' \
    -n "${ODF__INSTALL_NAMESPACE}" --for=condition=Progressing --timeout=5m 1>/dev/null

oc wait 'storagecluster.ocs.openshift.io/ocs-storagecluster' \
    -n "${ODF__INSTALL_NAMESPACE}" --for=condition='Available' --timeout="${ODF__STORAGE_CLUSTER_WAIT_TIMEOUT}" 1>/dev/null

# Remove is-default-class annotation from all storage classes, then promote
# ocs-storagecluster-ceph-rbd as the default storage class.
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

true
