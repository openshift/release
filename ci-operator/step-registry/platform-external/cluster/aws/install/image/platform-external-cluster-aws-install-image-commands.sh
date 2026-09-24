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

#
# Pick the installer binary whose bootimage matches the release being installed.
#
# This step runs in the upi-installer container, which is pinned per-config to a single OCP
# version. On upgrade jobs that pin is the TARGET version while the cluster is installed from
# release:initial, so the discovered bootimage can belong to a different release than the payload.
# When those releases straddle a RHCOS major version (5.0 is el10, 4.22 is el9) the bootstrap node
# boots el10 and then node-image-pull tries to `ostree container image pull` the payload's el9
# machine-os onto it. Skipping an OS major version needs the SELinux install_t domain to write
# security.selinux xattrs, which the unit does not get, so the import dies with
#   fsetxattr(security.selinux): Invalid argument
# and the API never comes up. See OPCT-487, RHEL-117251, RHEL-117256.
#
# So: if the container's version differs from the install payload's, discover the bootimage with
# the payload's own installer. Same approach as upi-conf-vsphere-platform-external. Versions match
# on every non-upgrade job, so the extract is skipped there and behaviour is unchanged.
INSTALLER_BINARY="openshift-install"

if [[ -n "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  # Build-farm release images (registry.build*.ci.openshift.org) need CI registry credentials on
  # top of the cluster-profile pull secret. platform-external-pre-conf already builds such a file
  # when it runs; fall back to logging in ourselves so this step does not depend on step ordering.
  PULL_SECRET="${SHARED_DIR}/pull-secret-with-ci"
  if [[ ! -s "${PULL_SECRET}" ]]; then
    PULL_SECRET="/tmp/pull-secret-with-ci"
    cp -f "${CLUSTER_PROFILE_DIR}/pull-secret" "${PULL_SECRET}"
    if [[ "$(dirname "$(dirname "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}")")" != "quay.io" ]]; then
      KUBECONFIG="" oc registry login --to "${PULL_SECRET}"
    fi
  fi

  # Both lookups are best-effort: a failure here must fall through to the upi-installer binary
  # rather than kill the step, so neither may trip `set -e`. `oc adm release info` stderr goes to
  # an artifact instead of the job log, which also keeps the release pullspec out of stdout.
  CONTAINER_VERSION="$(openshift-install version | awk '/^openshift-install/ {print $2; exit}' | cut -d. -f1,2 || true)"
  PAYLOAD_VERSION="$(oc adm release info -a "${PULL_SECRET}" \
    "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}' \
    2> "${ARTIFACT_DIR}/release-info-err.txt" | cut -d. -f1,2 || true)"

  if [[ -z "${PAYLOAD_VERSION}" ]]; then
    log "WARNING: could not read the install payload version, see ${ARTIFACT_DIR}/release-info-err.txt; using the upi-installer binary (${CONTAINER_VERSION:-unknown})"
  elif [[ "${PAYLOAD_VERSION}" == "${CONTAINER_VERSION}" ]]; then
    log "upi-installer and install payload are both ${PAYLOAD_VERSION}; using the upi-installer binary"
  else
    log "upi-installer is ${CONTAINER_VERSION} but the install payload is ${PAYLOAD_VERSION}; extracting the payload's installer so the bootimage matches"
    oc adm release extract -a "${PULL_SECRET}" \
      "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
      --command=openshift-install --to=/tmp
    chmod +x /tmp/openshift-install
    INSTALLER_BINARY=/tmp/openshift-install
  fi
else
  log "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is not set; using the upi-installer binary"
fi

log "openshift-install version used for bootimage discovery:"
"${INSTALLER_BINARY}" version

# begin bootstrapping
if "${INSTALLER_BINARY}" coreos print-stream-json 2> "${ARTIFACT_DIR}/err.txt" > /tmp/coreos.json; then
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.x86_64.images.aws.regions[$region].image' /tmp/coreos.json)"
  # if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]] || [[ "${OCP_ARCH}" == "arm64" ]]; then
  #   RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.architectures.aarch64.images.aws.regions[$region].image' coreos.json)"
  # fi
else
  RHCOS_AMI="$(jq -r --arg region "$AWS_REGION" '.amis[$region].hvm' /var/lib/openshift-install/rhcos.json)"
fi

log "Discovered RHCOS image ${RHCOS_AMI}, saving to artifact ${SHARED_DIR}/image_id.txt"
echo "${RHCOS_AMI}" > "${SHARED_DIR}/image_id.txt"
