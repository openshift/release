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

# TEMPORARY EXPERIMENT - MUST NOT MERGE.
# This step runs from the upi-installer image, which in an upgrade job is pinned
# to the target release (5.0), so print-stream-json returns 5.0's bootimage pin
# even though the payload being installed is the initial release (4.22).
# Observed: booted ami-0badc1f21372efea6 / RHCOS 10.2.20260423-0 = release-5.0 pin.
# Below forces release-4.22's us-west-2 pin to test whether that is what hangs
# bootstrap. Region guarded so other regions keep the current behaviour.
if [[ "${AWS_REGION}" == "us-west-2" ]]; then
  log "EXPERIMENT: overriding discovered AMI ${RHCOS_AMI} with release-4.22 pin"
  RHCOS_AMI="ami-09d49112a1306f262"
fi

log "Discovered RHCOS image ${RHCOS_AMI}, saving to artifact ${SHARED_DIR}/image_id.txt"
echo "${RHCOS_AMI}" > "${SHARED_DIR}/image_id.txt"
