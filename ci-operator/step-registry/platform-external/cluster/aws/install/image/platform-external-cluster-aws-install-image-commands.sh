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

export AWS_DEFAULT_REGION="${AWS_REGION}"  # CLI prefers the former

AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_SHARED_CREDENTIALS_FILE

# begin bootstrapping
if ! RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.x86_64.images.aws.regions[$region].image' ${SHARED_DIR}/coreos.json 2>"${ARTIFACT_DIR}/err.txt")"; then
  log "Failed to discover RHCOS image: $(cat "${ARTIFACT_DIR}/err.txt")"
  exit 1
fi
test -s "${ARTIFACT_DIR}/err.txt" && rm "${ARTIFACT_DIR}/err.txt" || true

if [[ -z "${RHCOS_AMI}" ]]; then
  log "Failed to discover RHCOS image, empty result for RHCOS_AMI=${RHCOS_AMI}"
  exit 1
fi

log "Discovered RHCOS image ${RHCOS_AMI}, saving to artifact ${SHARED_DIR}/image_id.txt"
echo "${RHCOS_AMI}" > "${SHARED_DIR}/image_id.txt"
