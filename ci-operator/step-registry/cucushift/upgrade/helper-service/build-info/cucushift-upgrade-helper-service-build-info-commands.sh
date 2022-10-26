#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

BUILD_INFO_FILE="${ARTIFACT_DIR}/ocp-build-info"

release_info() {
    local PAYLOAD_IMAGE=$1
    echo "Release info for: ${PAYLOAD_IMAGE}"
    oc adm release info "${PAYLOAD_IMAGE}" || true
    local VERSION
    VERSION="$(oc adm release info "${PAYLOAD_IMAGE}" --output=jsonpath="{.metadata.version}")"
    echo "${VERSION}" >> "${BUILD_INFO_FILE}"
}

release_info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
release_info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
