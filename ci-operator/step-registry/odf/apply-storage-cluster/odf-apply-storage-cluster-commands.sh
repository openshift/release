#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# DumpStorageCluster — write OLM / StorageCluster diagnostics to ARTIFACT_DIR on failure.
DumpStorageCluster() {
    typeset artifactDir="${ARTIFACT_DIR}/debug-info"
    mkdir -p "${artifactDir}"
    oc get csv,subscription.operators.coreos.com,installplan \
        -n "${ODF__INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/olm-resources.txt" 2>&1 || true
    oc get storagecluster ocs-storagecluster \
        -n "${ODF__INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/storagecluster.yaml" 2>&1 || true
    oc describe storagecluster ocs-storagecluster \
        -n "${ODF__INSTALL_NAMESPACE}" \
        > "${artifactDir}/storagecluster-describe.txt" 2>&1 || true
    true
}
trap DumpStorageCluster ERR INT TERM

# ocs-operator (a dependent of odf-operator) registers the StorageCluster CRD.
# install-operators only guarantees the odf-operator CSV; wait for the dependent here.
oc wait --for=create deployment/ocs-operator \
    -n "${ODF__INSTALL_NAMESPACE}" \
    --timeout="${ODF__OCS_OPERATOR_WAIT_TIMEOUT}" 1>/dev/null
oc wait deployment/ocs-operator \
    -n "${ODF__INSTALL_NAMESPACE}" \
    --for=condition=Available \
    --timeout="${ODF__OCS_OPERATOR_WAIT_TIMEOUT}" 1>/dev/null

# --for=condition=Established alone fails immediately with NotFound if the CRD is absent.
oc wait --for=create crd/storageclusters.ocs.openshift.io \
    --timeout="${ODF__CRD_WAIT_TIMEOUT}" 1>/dev/null
oc wait crd/storageclusters.ocs.openshift.io \
    --for=condition=Established \
    --timeout="${ODF__CRD_WAIT_TIMEOUT}" 1>/dev/null

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

oc wait 'storagecluster.ocs.openshift.io/ocs-storagecluster' \
    -n "${ODF__INSTALL_NAMESPACE}" \
    --for=condition=Available \
    --timeout="${ODF__STORAGE_CLUSTER_WAIT_TIMEOUT}" 1>/dev/null

# Remove is-default-class annotation from all storage classes, then promote
# ocs-storagecluster-ceph-rbd as the default storage class.
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

true
