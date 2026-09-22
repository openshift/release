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
# Observed twice: booted RHCOS 10.2.20260423-0 = release-5.0 pin, bootstrap hung.
# Below forces release-4.22's pin (10.2.20260715-0) to test whether that is the
# cause. Covers every region in the openshift-org-aws lease pool, since the lease
# picks from us-east-1, us-east-2, us-west-1 and us-west-2.
# Values from openshift/installer release-4.22 data/data/coreos/coreos-rhel-10.json.
case "${AWS_REGION}" in
  us-east-1) RHCOS_AMI_4_22="ami-026c3565b2e140a8f" ;;
  us-east-2) RHCOS_AMI_4_22="ami-00bceb1d4863de8d5" ;;
  us-west-1) RHCOS_AMI_4_22="ami-030623e6ced67aefc" ;;
  us-west-2) RHCOS_AMI_4_22="ami-09d49112a1306f262" ;;
  *)         RHCOS_AMI_4_22="" ;;
esac

if [[ -n "${RHCOS_AMI_4_22}" ]]; then
  log "EXPERIMENT: region ${AWS_REGION}, overriding discovered AMI ${RHCOS_AMI} with release-4.22 pin ${RHCOS_AMI_4_22}"
  RHCOS_AMI="${RHCOS_AMI_4_22}"
else
  log "EXPERIMENT: no release-4.22 pin known for region ${AWS_REGION}, keeping discovered AMI ${RHCOS_AMI} - this run does NOT test the hypothesis"
fi

log "Discovered RHCOS image ${RHCOS_AMI}, saving to artifact ${SHARED_DIR}/image_id.txt"
echo "${RHCOS_AMI}" > "${SHARED_DIR}/image_id.txt"
