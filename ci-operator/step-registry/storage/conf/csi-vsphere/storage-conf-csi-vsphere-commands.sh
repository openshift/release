#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cd /go/src/github.com/openshift/vmware-vsphere-csi-driver-operator
if [ "${IS_HYBRID_ENV}" = "false" ]; then
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
else
    cp test/e2e/manifests-hybrid.yaml ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ] && [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
    cp test/e2e/ocp-tests.yaml ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
    echo "Using OCP specific manifest ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}:"
    cat ${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
