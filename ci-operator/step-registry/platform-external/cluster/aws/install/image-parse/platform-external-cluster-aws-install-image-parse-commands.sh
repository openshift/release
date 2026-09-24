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

jq -r --arg region "$AWS_REGION" '.architectures.x86_64.images.aws.regions[$region].image' ${SHARED_DIR}/coreos.json | tee "${SHARED_DIR}/image_id.txt"
log "Discovered RHCOS Image ID: $(cat "${SHARED_DIR}/image_id.txt")"
