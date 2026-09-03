#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator
    cp test/e2e/azure-file/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
    if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ]; then
        # After csi-operator#596: ocp-manifest.yaml is standard, ocp-manifest-long.yaml is LUN stress.
        # Older branches have only the combined ocp-manifest.yaml (LUN stress). Copy that on long
        # jobs when the split is absent; copy the standard file on short jobs only when the split exists.
        ocp_dir="test/e2e/azure-file"
        ocp_dest="${SHARED_DIR}/${TEST_OCP_CSI_DRIVER_MANIFEST}"
        if [ "${ENABLE_LONG_CSI_CERTIFICATION_TESTS}" = "true" ]; then
            if [ -f "${ocp_dir}/ocp-manifest-long.yaml" ]; then
                cp "${ocp_dir}/ocp-manifest-long.yaml" "${ocp_dest}"
            elif [ -f "${ocp_dir}/ocp-manifest.yaml" ]; then
                cp "${ocp_dir}/ocp-manifest.yaml" "${ocp_dest}"
            fi
        elif [ -f "${ocp_dir}/ocp-manifest-long.yaml" ] && [ -f "${ocp_dir}/ocp-manifest.yaml" ]; then
            cp "${ocp_dir}/ocp-manifest.yaml" "${ocp_dest}"
        fi
        if [ -f "${ocp_dest}" ]; then
            echo "Using OCP specific manifest ${ocp_dest}:"
            cat "${ocp_dest}"
        fi
    fi
else
    echo "Using azure-file-csi-driver-operator repo"
    cd /go/src/github.com/openshift/azure-file-csi-driver-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
