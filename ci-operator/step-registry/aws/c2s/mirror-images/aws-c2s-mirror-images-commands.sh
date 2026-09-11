#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

new_pull_secret="${SHARED_DIR}/new_pull_secret"

# private mirror registry host
# <public_dns>:<port>
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

oc registry login

# combine custom registry credential and default pull secret
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# OCP_ARCH is only set explicitly for non-amd64 clusters; default to amd64
OCP_ARCH="${OCP_ARCH:-amd64}"

# C2S helper images are published per-arch. amd64 uses the ":latest" tag;
# the multi-arch build is published as ":multi-latest". Select the source tag
# based on the cluster architecture. The destination tag stays ":latest" so the
# on-cluster consumers (MachineConfig podman run, cap-token-refresh CronJob)
# need no change.
HELPER_IMAGE_TAG="latest"
if [[ "${OCP_ARCH}" == "arm64" ]]; then
    HELPER_IMAGE_TAG="multi-latest"
fi
echo "Mirroring C2S helper images using source tag: ${HELPER_IMAGE_TAG} (arch: ${OCP_ARCH})"

# Since the CI step container is amd64, "oc image mirror" defaults to selecting
# the amd64 sub-manifest from the ":multi-latest" manifest list. Pin the mirrored
# architecture to the cluster arch so an arm64 cluster gets the arm64 image rather than the step container's amd64.
FILTER_BY_OS="linux/${OCP_ARCH}"

# MIRROR IMAGES
oc image mirror -a "${new_pull_secret}" \
    quay.io/openshift-install/c2s-instance-metadata:${HELPER_IMAGE_TAG}=${MIRROR_REGISTRY_HOST}/openshift-install/c2s-instance-metadata:latest \
    --filter-by-os="${FILTER_BY_OS}" \
    --insecure=true --skip-missing=true --skip-verification=true

oc image mirror -a "${new_pull_secret}" \
    quay.io/openshift-install/cap-token-refresh:${HELPER_IMAGE_TAG}=${MIRROR_REGISTRY_HOST}/openshift-install/cap-token-refresh:latest \
    --filter-by-os="${FILTER_BY_OS}" \
    --insecure=true --skip-missing=true --skip-verification=true

rm -f "${new_pull_secret}"
