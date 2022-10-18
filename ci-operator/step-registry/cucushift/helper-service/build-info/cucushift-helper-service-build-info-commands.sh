#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Release info for: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" || true
PAYLOAD_VERSION="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --output=jsonpath="{.metadata.version}" || true)"
echo "${PAYLOAD_VERSION}" > "${ARTIFACT_DIR}/ocp-build-info"
