#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

# MIRROR IMAGES
oc image mirror -a "${new_pull_secret}" \
    quay.io/yunjiang/c2s-instance-metadata:latest=${MIRROR_REGISTRY_HOST}/yunjiang/c2s-instance-metadata:latest \
    --insecure=true --skip-missing=true --skip-verification=true

oc image mirror -a "${new_pull_secret}" \
    quay.io/yunjiang/cap-token-refresh:latest=${MIRROR_REGISTRY_HOST}/yunjiang/cap-token-refresh:latest \
    --insecure=true --skip-missing=true --skip-verification=true

rm -f "${new_pull_secret}"
