#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -n "${RELEASE_IMAGE_LATEST}" ]]; then
    echo "Release info for: ${RELEASE_IMAGE_LATEST}"
    oc adm release info "${RELEASE_IMAGE_LATEST}" || true
    PAYLOAD_VERSION="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=jsonpath="{.metadata.version}")"
    echo "${PAYLOAD_VERSION}" > "${ARTIFACT_DIR}/ocp-build-info"
fi
