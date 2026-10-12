#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ -d /go/src/github.com/openshift/csi-operator/test/e2e/gcp-pd/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator
    GCPPD="gcp-pd"
elif [ -d /go/src/github.com/openshift/csi-operator/legacy/gcp-pd-csi-driver-operator/ ]; then
    echo "Using csi-operator repo legacy dir"
    cd /go/src/github.com/openshift/csi-operator/legacy/gcp-pd-csi-driver-operator
    GCPPD="."
else
    echo "Using gcp-pd-csi-driver-operator repo"
    cd /go/src/github.com/openshift/gcp-pd-csi-driver-operator
    GCPPD="."
fi

if [ "${IMAGE_VOLUME_SNAPSHOT_MANIFEST:-}" = "image-snapshot" ]; then
    echo "Copying image-snapshot-manifest.yaml to ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"
    cp test/e2e/${GCPPD}/image-snapshot-manifest.yaml "${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"
    cat "${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}"
elif [ "${COMPUTE_DISK_TYPE}" == "hyperdisk-balanced" ]; then
    # Using hyperdisk-balanced worker
    cp test/e2e/${GCPPD}/hyperdisk-manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
else
    cp test/e2e/${GCPPD}/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

if [ -f "test/e2e/${GCPPD}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}" ]; then
    echo "Copying ${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST} to ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}"
    cp test/e2e/${GCPPD}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST} ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}
    cat ${SHARED_DIR}/${TEST_VOLUME_ATTRIBUTES_CLASS_MANIFEST}
fi

if [ -n "${TEST_OCP_CSI_DRIVER_MANIFEST}" ]; then
    ocp_dir="test/e2e/${GCPPD}"
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

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
