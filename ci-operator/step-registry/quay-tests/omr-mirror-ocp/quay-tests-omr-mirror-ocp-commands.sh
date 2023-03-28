#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#check versions
oc version
openshift-install version

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

mirror_output="${SHARED_DIR}/mirror_output"
new_pull_secret="${SHARED_DIR}/new_pull_secret"
install_config_icsp_patch="${SHARED_DIR}/install-config-icsp.yaml.patch"
icsp_file="${SHARED_DIR}/local_registry_icsp_file.yaml"

echo "${OPENSHIFT_INSTALL_RELEASE_IMAGE}" || true

OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
OMR_HOST="${OMR_HOST_NAME}:8443"
OMR_CRED="cXVheTpwYXNzd29yZA=="
echo "Start to mirror OCP Images to OMR $OMR_HOST_NAME ..."

target_release_image="${OMR_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"

echo "${target_release_image_repo}" || true
echo "${target_release_image}" || true

#Login the image registry of build farm
unset KUBECONFIG
oc registry login

jq --argjson a "{\"${OMR_HOST}\": {\"auth\": \"$OMR_CRED\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# MIRROR IMAGES to OMR
oc adm release -a "${new_pull_secret}" mirror --insecure=true \
 --from=${OPENSHIFT_INSTALL_RELEASE_IMAGE} \
 --to=${target_release_image_repo} \
 --to-release-image=${target_release_image} | tee "${mirror_output}" || true

grep -B 1 -A 10 "kind: ImageContentSourcePolicy" ${mirror_output} > "${icsp_file}"
grep -A 6 "imageContentSources" ${mirror_output} > "${install_config_icsp_patch}"
head -7 "${install_config_icsp_patch}" > "${SHARED_DIR}/install-config-mirrors"

cat "${icsp_file}"
cat "${install_config_icsp_patch}"
