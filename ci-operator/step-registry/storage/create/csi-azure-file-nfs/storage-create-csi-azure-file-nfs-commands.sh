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

# NFS is supported for snap/clone since 4.21 and along with it we added the manifest to csi-operator repo to have better control over capabilities (per branch)
if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    if [ -f /go/src/github.com/openshift/csi-operator/test/e2e/azure-file-nfs/manifest.yaml ]; then
        echo "Using test manifest for Azure File NFS"
        cd /go/src/github.com/openshift/csi-operator
        cp test/e2e/azure-file-nfs/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
    else
        echo "Test manifest for Azure File NFS not found in csi-operator repo - this is expected in OpenShift < 4.21"
    fi
else
    # Historically Azure File Operator was in different repo without manifest file, later was moved to csi-operator but did not have manifest file until OpenShift 4.21
    # For those cases we need to create the manifest here.
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
fi

echo "Using manifest file ${MANIFEST_LOCATION}"
cat ${MANIFEST_LOCATION}
