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
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='10m'

echo "Remove is-default-class annotation from all the storage classes"
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-

echo "Make ocs-storagecluster-ceph-rbd the default storage class"
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

echo "ODF Operator is deployed successfully"
