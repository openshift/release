#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -z "${TEST_CSI_DRIVER_MANIFEST}" && "${TEST_CSI_DRIVER_MANIFEST}" != *"cinder"* ]]; then
    echo "TEST_CSI_DRIVER_MANIFEST is empty or doesn't contain cinder, skipping the step"
    exit 0
fi

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator/
    cp test/e2e/openstack-cinder/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
else
    echo "Using regular csi directory"
    cd /go/src/github.com/openshift/openstack-cinder-csi-driver-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
