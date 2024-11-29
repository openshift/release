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
# ToDo(mtulio): move to step var when enabling multi-arch.
#export OCP_ARCH=amd64

# begin bootstrapping
if openshift-install coreos print-stream-json 2> "${ARTIFACT_DIR}/err.txt" > /tmp/coreos.json; then
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.x86_64.images.aws.regions[$region].image' /tmp/coreos.json)"
  # if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]] || [[ "${OCP_ARCH}" == "arm64" ]]; then
  #   RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.aarch64.images.aws.regions[$region].image' coreos.json)"
  # fi
else
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.amis[$region].hvm' /var/lib/openshift-install/rhcos.json)"
fi

log "Discovered RHCOS image ${RHCOS_AMI}, saving to artifact ${SHARED_DIR}/image_id.txt"
echo "${RHCOS_AMI}" > "${SHARED_DIR}/image_id.txt"
