#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Applying StorageSystem after operator installation completed"

cat <<EOF | oc apply -f -
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: "${ODF_INSTALL_NAMESPACE}"
EOF

sleep 120

echo "Creating a StorageClass"

cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
  name: csi-odf
parameters:
  StoragePolicyName: "vSAN Default Storage Policy"
provisioner: "${BASE_DOMAIN}"
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

sleep 120

echo "Deploying a StorageCluster"
cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  resources:
    mds:
      Limits: null
      Requests: null
    mgr:
      Limits: null
      Requests: null
    mon:
      Limits: null
      Requests: null
    noobaa-core:
      Limits: null
      Requests: null
    noobaa-db:
      Limits: null
      Requests: null
    noobaa-endpoint:
      limits:
        cpu: 1
        memory: 500Mi
      requests:
        cpu: 1
        memory: 500Mi
    rgw:
      Limits: null
      Requests: null
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 256Gi
        storageClassName: thin-csi-odf
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources:
      Limits: null
      Requests: null
EOF

# Need to allow some time before checking if the StorageCluster is deployed
sleep 60

echo "⏳ Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='180m'

echo "Remove is-default-class annotation from all the storage classes"
oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-

echo "Make ocs-storagecluster-ceph-rbd the default storage class"
oc annotate storageclass ocs-storagecluster-ceph-rbd storageclass.kubernetes.io/is-default-class=true

echo "ODF Operator is deployed successfully"