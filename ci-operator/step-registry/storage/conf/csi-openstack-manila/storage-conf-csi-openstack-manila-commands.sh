#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -z "${TEST_CSI_DRIVER_MANIFEST}" ]]; then
    echo "TEST_CSI_DRIVER_MANIFEST is empty, skipping the step"
    exit 0
fi

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator/
    cp test/e2e/openstack-manila/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
else
    echo "Using regular csi directory"
    cd /go/src/github.com/openshift/csi-driver-manila-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
