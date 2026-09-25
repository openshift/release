#!/usr/bin/env bash

#
# Discover RHCOS image to install using UPI.
#

set -euo pipefail

source "${SHARED_DIR}/init-fn.sh" || true

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  log "Failed to acquire lease"
  exit 1
fi

AWS_REGION=${LEASED_RESOURCE}
AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_SHARED_CREDENTIALS_FILE

INSTALLER_BINARY="openshift-install"

if ! openshift-install coreos print-stream-json 2> "${ARTIFACT_DIR}/err.txt" > ${SHARED_DIR}/coreos.json; then
  log "Failed to discover RHCOS image: $(cat "${ARTIFACT_DIR}/err.txt")"
  exit 1
fi

log "openshift-install version used for bootimage discovery:"
"${INSTALLER_BINARY}" version | grep -E "(openshift-install|build|release|architecture)"
