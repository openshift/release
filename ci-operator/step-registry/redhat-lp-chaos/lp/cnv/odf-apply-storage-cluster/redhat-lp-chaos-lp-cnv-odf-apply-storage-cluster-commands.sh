#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

: "Wait for StorageCluster CRD to be created"
timeout 5m bash -c '
    until oc get crd storageclusters.ocs.openshift.io &>/dev/null; do
        sleep 5
    done
'

: "Deploying StorageCluster"
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

# OCS operator reconciliation is asynchronous; without this pause the oc wait
# below can race against the controller before it has registered the status conditions.
sleep 60

: "Wait for StorageCluster to become Available"
oc wait 'storagecluster.ocs.openshift.io/ocs-storagecluster' \
    -n "${ODF_INSTALL_NAMESPACE}" --for=condition='Available' --timeout='25m'

: "Remove is-default-class annotation from all storage classes"
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-

: "Make ocs-storagecluster-ceph-rbd the default storage class"
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

true
