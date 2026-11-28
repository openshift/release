#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Creating LocalVolume for block device ${LSO_DEVICE_PATH}"
oc apply -f - <<EOF
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: local-block
  namespace: openshift-local-storage
spec:
  storageClassDevices:
  - storageClassName: localblock
    volumeMode: Block
    devicePaths:
    - ${LSO_DEVICE_PATH}
EOF

echo "Waiting for LocalVolume to become Available"
oc wait LocalVolume/local-block -n openshift-local-storage \
  --for=condition=Available --timeout=15m
