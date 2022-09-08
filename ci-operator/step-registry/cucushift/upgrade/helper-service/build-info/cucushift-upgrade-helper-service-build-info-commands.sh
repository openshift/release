#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

BUILD_INFO_FILE="${ARTIFACT_DIR}/ocp-build-info"

if [[ -n "${RELEASE_IMAGE_LATEST}" ]]; then
    echo "Release info for: ${RELEASE_IMAGE_LATEST}"
    oc adm release info "${RELEASE_IMAGE_LATEST}" || true
    LATEST_VERSION="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=jsonpath="{.metadata.version}")"
    echo "${LATEST_VERSION}" > "${BUILD_INFO_FILE}"
fi
