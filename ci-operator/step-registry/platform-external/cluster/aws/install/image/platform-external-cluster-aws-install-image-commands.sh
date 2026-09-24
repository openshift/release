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

# DO NOT MERGE — OPCT-486: force the release-4.22 el9 bootimage AMI.
#
# The upi-installer container is pinned to 5.0, so the discovery above runs the 5.0 binary and
# returns 5.0's el10 bootimage (RHCOS 10.2.x). But the payload being installed is 4.22, whose
# rhel-coreos StreamTag is el9 (machine-os 9.8.x). node-image-pull.sh then tries to
# `ostree container image pull` an el9 OS image onto an el10 host — skipping an OS major version.
# That needs the SELinux install_t domain to write cross-major security.selinux xattrs, which the
# unit does not get, so the import dies with
#   fsetxattr(security.selinux): Invalid argument
# (RHEL-117251 / RHEL-117256). On the older 5.0 bootimage the same skew instead SIGABRTs inside
# bootc-1.13.0.
#
# The passing non-upgrade 4.22 job discovers ami-0399f6912ea26e33c in us-west-1 — which is the
# el9 stream — so it is el9 bootimage + el9 machine-os, matched, and it works.
#
# An earlier revision of this block pinned AMIs from coreos-rhel-10.json, which kept the el10/el9
# skew intact and so tested nothing. Values below are from
# openshift/installer data/data/coreos/coreos-rhel-9.json?ref=release-4.22, release 9.8.20260715-1.
# Paired with the release-image override (commit d0e86529ba4) so release-image.service can pull.
case "${AWS_REGION}" in
  us-east-1) RHCOS_AMI_4_22="ami-0980843632a1c3a66" ;;
  us-east-2) RHCOS_AMI_4_22="ami-03b58703d4e9ea61a" ;;
  us-west-1) RHCOS_AMI_4_22="ami-0399f6912ea26e33c" ;;
  us-west-2) RHCOS_AMI_4_22="ami-01d48aa6b50f9d0df" ;;
  *)         RHCOS_AMI_4_22="" ;;
esac
if [[ -n "${RHCOS_AMI_4_22}" ]]; then
  log "EXPERIMENT: region ${AWS_REGION}, overriding discovered AMI ${RHCOS_AMI} with release-4.22 el9 pin ${RHCOS_AMI_4_22}"
  RHCOS_AMI="${RHCOS_AMI_4_22}"
else
  log "EXPERIMENT: region ${AWS_REGION} has no release-4.22 el9 pin; leaving discovered AMI ${RHCOS_AMI} (test INCONCLUSIVE this run)"
fi

log "Discovered RHCOS image ${RHCOS_AMI}, saving to artifact ${SHARED_DIR}/image_id.txt"
echo "${RHCOS_AMI}" > "${SHARED_DIR}/image_id.txt"
