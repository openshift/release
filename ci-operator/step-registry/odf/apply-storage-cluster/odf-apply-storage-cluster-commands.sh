#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

## Temp debug
# trap 'sleep 4h' EXIT SIGINT SIGTERM

echo "Deploying a StorageCluster"
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

sleep 4h

# Need to allow some time before checking if the StorageCluster is deployed
sleep 60

echo "⏳ Wait for StorageCluster to be deployed"
oc wait "storagecluster.ocs.openshift.io/ocs-storagecluster"  \
    -n $ODF_INSTALL_NAMESPACE --for=condition='Available' --timeout='180m'

echo "ODF Operator is deployed successfully"