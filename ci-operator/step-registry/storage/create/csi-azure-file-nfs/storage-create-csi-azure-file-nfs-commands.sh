#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export STORAGECLASS_LOCATION="${SHARED_DIR}/azurefile-nfs-sc.yaml"
export MANIFEST_LOCATION="${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"

# Create StorageClass
echo "Creating a StorageClass"
cat <<EOF >"${STORAGECLASS_LOCATION}"
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

echo "StorageClass file is stored at ${STORAGECLASS_LOCATION} with content:"
cat "${STORAGECLASS_LOCATION}"

oc create -f "${STORAGECLASS_LOCATION}"
echo "Created StorageClass from file: ${STORAGECLASS_LOCATION}"

# Historically Azure File Operator was in different repo than csi-operator, then it was moved to csi-operator in 4.16, but did not contain the test manifest file until 4.21.
# This results in 3 different cases that can occur during the job run:
# Case 1: <4.16 - Azure File Operator was in azure-file-csi-driver-operator repo which did not contain the manifest file -> we need to generate it here.
# Case 2: 4.16-4.20 - Azure File Operator is in csi-operator repo but does not have the manifest file -> we need to generate it here.
# Case 3: 4.21+ - Azure File Operator is in csi-operator repo and has the manifest file, we should use it.

CSI_OPERATOR_DIR="/go/src/github.com/openshift/csi-operator"
MANIFEST_SOURCE="${CSI_OPERATOR_DIR}/test/e2e/azure-file-nfs/manifest.yaml"

if [[ -d "${CSI_OPERATOR_DIR}" && -f "${MANIFEST_SOURCE}" ]]; then
    # Case 3
    echo "OpenShift 4.21+: Using manifest from csi-operator repository"
    if ! cp "${MANIFEST_SOURCE}" "${MANIFEST_LOCATION}"; then
        echo "ERROR: Failed to copy manifest file"
        exit 1
    fi
else
    # Case 1 or 2
    echo "Manifest file not found in csi-operator repository or csi-operator directory not found, creating a manifest file"
    cat <<EOF >"${MANIFEST_LOCATION}"
# Test manifest for https://github.com/kubernetes/kubernetes/tree/master/test/e2e/storage/external
ShortName: azurefile-nfs
StorageClass:
  FromExistingClassName: azurefile-csi-nfs
SnapshotClass:
  FromName: true
DriverInfo:
  Name: file.csi.azure.com
  SupportedSizeRange:
    Min: 100Gi
    Max: 1Ti
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

echo "Manifest file stored at ${MANIFEST_LOCATION} with content:"
cat "${MANIFEST_LOCATION}"
