#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator
    cp test/e2e/aws-ebs/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
    if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ] && [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
        cp test/e2e/aws-ebs/ocp-manifest.yaml ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
        echo "Using OCP specific manifest ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}:"
        cat ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
    fi
    if [ -f "test/e2e/aws-ebs/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}" ]; then
        echo "Copying ${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST} to ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}"
        cp test/e2e/aws-ebs/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST} ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}
        cat ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}
    fi
else
    echo "Using aws-ebs-csi-driver-operator repo"
    cd /go/src/github.com/openshift/aws-ebs-csi-driver-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
