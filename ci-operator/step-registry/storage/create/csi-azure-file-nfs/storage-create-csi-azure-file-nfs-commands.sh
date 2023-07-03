#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export STORAGECLASS_LOCATION=${SHARED_DIR}/azurefile-nfs-sc.yaml
export MANIFEST_LOCATION=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}

# Create StorageClass
echo "Creating a StorageClass"
cat <<EOF >>$STORAGECLASS_LOCATION
# Taken from https://github.com/kubernetes-sigs/azurefile-csi-driver/blob/master/deploy/example/storageclass-azurefile-nfs.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi-nfs
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nconnect=4
EOF

echo "Using StorageClass file ${STORAGECLASS_LOCATION}"
cat ${STORAGECLASS_LOCATION}

oc create -f ${STORAGECLASS_LOCATION}
echo "Created StorageClass from file ${STORAGECLASS_LOCATION}"

# Create test manifest
echo "Creating a manifest file"
cat <<EOF >>$MANIFEST_LOCATION
# Test manifest for https://github.com/kubernetes/kubernetes/tree/master/test/e2e/storage/external
ShortName: azurefile-nfs
StorageClass:
  FromExistingClassName: azurefile-csi-nfs
SnapshotClass:
  FromName: true
DriverInfo:
  Name: file.csi.azure.com
  Capabilities:
    persistence: true
    exec: true
    multipods: true
    RWX: true
    fsGroup: true
    volumeMountGroup: true
    topology: false
    controllerExpansion: true
    nodeExpansion: true
    volumeLimits: false
    snapshotDataSource: false
EOF

echo "Using manifest file ${MANIFEST_LOCATION}"
cat ${MANIFEST_LOCATION}
