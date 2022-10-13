#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

BUILD_INFO_FILE="${ARTIFACT_DIR}/ocp-build-info"

if [[ -n "${RELEASE_IMAGE_LATEST}" ]]; then
    echo "Release info for: ${RELEASE_IMAGE_LATEST}"
    oc adm release info "${RELEASE_IMAGE_LATEST}" || true
    LATEST_VERSION="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=jsonpath="{.metadata.version}")"
    echo "${LATEST_VERSION}" >> "${BUILD_INFO_FILE}"
fi
if [[ -n "${RELEASE_IMAGE_TARGET}" ]]; then 
    echo "Release info for: ${RELEASE_IMAGE_TARGET}"
    oc adm release info "${RELEASE_IMAGE_TARGET}" || true
    TARGET_VERSION="$(oc adm release info "${RELEASE_IMAGE_TARGET}" --output=jsonpath="{.metadata.version}")"
    echo "${TARGET_VERSION}" >> "${BUILD_INFO_FILE}"
fi