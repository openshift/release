#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi-ultrassd
provisioner: disk.csi.azure.com
parameters:
  skuName: UltraSSD_LRS
  # UltraSSD_LRS only support None caching mode
  cachingMode: None
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
