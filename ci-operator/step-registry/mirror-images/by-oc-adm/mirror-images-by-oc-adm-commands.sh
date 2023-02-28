#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

mirror_output="${SHARED_DIR}/mirror_output"
new_pull_secret="${SHARED_DIR}/new_pull_secret"
install_config_icsp_patch="${SHARED_DIR}/install-config-icsp.yaml.patch"
icsp_file="${SHARED_DIR}/local_registry_icsp_file.yaml"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

readable_version=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
echo "readable_version: $readable_version"

# target release
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
# ensure mirror release image by tag name, refer to https://github.com/openshift/oc/pull/1331
target_release_image="${target_release_image_repo}:${readable_version}"

echo "target_release_image: $target_release_image"
echo "target_release_image_repo: $target_release_image_repo"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG
oc registry login

# combine custom registry credential and default pull secret
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# MIRROR IMAGES
oc adm release -a "${new_pull_secret}" mirror --insecure=true \
 --from=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} \
 --to=${target_release_image_repo} \
 --to-release-image=${target_release_image} | tee "${mirror_output}"

grep -B 1 -A 10 "kind: ImageContentSourcePolicy" ${mirror_output} > "${icsp_file}"
grep -A 6 "imageContentSources" ${mirror_output} > "${install_config_icsp_patch}"

echo "${install_config_icsp_patch}:"
cat "${install_config_icsp_patch}"
rm -f "${new_pull_secret}"
