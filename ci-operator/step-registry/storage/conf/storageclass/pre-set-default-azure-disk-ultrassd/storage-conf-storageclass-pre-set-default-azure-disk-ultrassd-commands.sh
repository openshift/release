#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cat << EOF > ${SHARED_DIR}/manifest_storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-ultrassd
provisioner: disk.csi.azure.com
parameters:
  skuName: UltraSSD_LRS
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
