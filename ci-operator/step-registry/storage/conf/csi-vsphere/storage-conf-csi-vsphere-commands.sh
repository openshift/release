#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export VSPHERE_DATASTORE_PATH="ds:///vmfs/volumes/vsan:86c7dbc3da924855-b20d5cd1f4eec976/"
VSPHERE_CLUSTER_LOCATION=$(cat ${SHARED_DIR}/vsphere_cluster_location)

if [ "$VSPHERE_CLUSTER_LOCATION" == "IBM" ]; then
    export VSPHERE_DATASTORE_PATH="ds:///vmfs/volumes/vsan:523ea352e875627d-b090c96b526bb79c/"
fi

cd /go/src/github.com/openshift/vmware-vsphere-csi-driver-operator
envsubst < test/e2e/storageclass-ci.yaml > test/e2e/storageclass-ci.yaml
cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
