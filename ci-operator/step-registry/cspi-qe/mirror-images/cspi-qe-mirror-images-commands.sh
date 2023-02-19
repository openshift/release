#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

new_pull_secret="${SHARED_DIR}/new_pull_secret"
image="quay.io/${QUAY_REPO}/${IMAGE_NAME}:${IMAGE_TAG}=MIRROR_REGISTRY_PLACEHOLDER/cspi-qe/${IMAGE_NAME}:${IMAGE_TAG}"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG

# combine custom registry credential and default pull secret
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# MIRROR IMAGES
# Creating ICSP for quay.io/openshiftteste is in enable-qe-catalogsource-disconnected step
# Set Node CA for Mirror Registry is in enable-qe-catalogsource-disconnected step
sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_REGISTRY_HOST}/g" "/tmp/mirror-images-list.yaml"

oc image mirror $image  --insecure=true -a "${new_pull_secret}" --skip-missing=true --skip-verification=true --keep-manifest-list=true --filter-by-os='.*'
rm -f "${new_pull_secret}"

