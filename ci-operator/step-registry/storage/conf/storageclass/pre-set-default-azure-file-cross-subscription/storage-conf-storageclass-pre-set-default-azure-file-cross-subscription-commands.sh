#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Abort the job if the cross subscription is not created
if [[ ! -f "${SHARED_DIR}/resourcegroup_cross-sub" ]]; then
  echo "Error: The cross subscription is not created, exit!"
  exit 1
fi
CROSS_SUBSCRIPTION_RESOURCEGROUP="$(<"${SHARED_DIR}/resourcegroup_cross-sub")"
CROSS_SUBSCRIPTION_ID="$(<"${SHARED_DIR}/cross_subscription_id")"

cat << EOF > ${SHARED_DIR}/manifest_storageclass.yaml
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-csi
mountOptions:
- mfsymlinks
- cache=strict
- nosharesock
- actimeo=30
parameters:
  matchTags: "true"
  skuName: Standard_LRS
  tags: storageClassName=azurefile-csi
  subscriptionID: ${CROSS_SUBSCRIPTION_ID}
  resourceGroup: ${CROSS_SUBSCRIPTION_RESOURCEGROUP}
provisioner: file.csi.azure.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

cat << EOF > ${SHARED_DIR}/manifest_cluster_csi_driver.yaml
apiVersion: operator.openshift.io/v1
kind: "ClusterCSIDriver"
metadata:
  name: "file.csi.azure.com"
spec:
  logLevel: Normal
  managementState: Managed
  operatorLogLevel: Normal
  storageClassState: Unmanaged
EOF
