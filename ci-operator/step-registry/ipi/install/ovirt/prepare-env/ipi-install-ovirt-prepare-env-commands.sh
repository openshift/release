#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

cp "${CLUSTER_PROFILE_DIR}/csi-test-manifest.yaml" "${SHARED_DIR}"
