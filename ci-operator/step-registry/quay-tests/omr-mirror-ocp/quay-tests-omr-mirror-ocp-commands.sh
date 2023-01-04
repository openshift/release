#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Check oc and ocp installer version
echo "What's the oc version?"
oc version

mirror_output="${SHARED_DIR}/mirror_output"
new_pull_secret="${SHARED_DIR}/new_pull_secret"

echo "What's the ocp installer version?"
openshift-install version

echo "${OPENSHIFT_INSTALL_RELEASE_IMAGE}" || true

cat "${CLUSTER_PROFILE_DIR}/pull-secret"

OMR_HOST_NAME=$(cat ${SHARED_DIR}/OMR_HOST_NAME)
OMR_HOST="${OMR_HOST_NAME}:8443"
OMR_CRED="cXVheTpwYXNzd29yZA=="
echo "Start to mirror OCP Images to OMR $OMR_HOST_NAME ..."

target_release_image_repo="${OMR_HOST_NAME}:8443/openshift-release-dev/ocp-release"
target_release_image="${target_release_image_repo}:4.12-x86_64"

echo "${target_release_image_repo}" || true
echo "${target_release_image}" || true

# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG
oc registry login

jq --argjson a "{\"${OMR_HOST}\": {\"auth\": \"$OMR_CRED\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

cat "${new_pull_secret}" | jq || true

# MIRROR IMAGES
oc adm release -a "${new_pull_secret}" mirror --insecure=true \
 --from=${OPENSHIFT_INSTALL_RELEASE_IMAGE} \
 --to=${target_release_image_repo} \
 --to-release-image=${target_release_image} | tee "${mirror_output}" || true

