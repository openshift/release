#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator
    cp test/e2e/aws-ebs/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
else
    echo "Using aws-ebs-csi-driver-operator repo"
    cd /go/src/github.com/openshift/aws-ebs-csi-driver-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
