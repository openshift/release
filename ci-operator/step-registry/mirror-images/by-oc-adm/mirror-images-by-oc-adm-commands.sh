#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ "${MIRROR_BIN}" != "oc-adm" ]]; then
  echo "users specifically do not use oc-adm to run mirror"
  exit 0
fi

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

mirror_output="${SHARED_DIR}/mirror_output"
new_pull_secret="${SHARED_DIR}/new_pull_secret"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
cluster_mirror_conf_file="${SHARED_DIR}/local_registry_mirror_file.yaml"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG
oc registry login

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

# combine custom registry credential and default pull secret
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

mirror_crd_type='icsp'
regex_keyword_1="imageContentSources"
if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    mirror_crd_type='idms'
    regex_keyword_1="imageDigestSources"
fi

# set the release mirror args
args=(
    --from="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
    --to-release-image="${target_release_image}"
    --to="${target_release_image_repo}"
    --insecure=true
)

run_command "which oc"
run_command "oc version --client"

# check whether the oc command supports extra options and add them to the args array.
if oc adm release mirror -h | grep -q -- --keep-manifest-list; then
    echo "Adding --keep-manifest-list to the mirror command."
    args+=(--keep-manifest-list=true)
else
    echo "This version of oc does not support --keep-manifest-list, skip it."
fi

if oc adm release mirror -h | grep -q -- --print-mirror-instructions; then
    echo "Adding --print-mirror-instructions to the mirror command."
    args+=(--print-mirror-instructions="${mirror_crd_type}")
else
    echo "This version of oc does not support --print-mirror-instructions=, skip it."
fi

# For disconnected or otherwise unreachable mirrors, we want to
# have steps use an HTTP(S) proxy to reach the mirror. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/mirror-proxy-conf.sh"
then
        # shellcheck disable=SC1090
        source "${SHARED_DIR}/mirror-proxy-conf.sh"
fi

# execute the mirror command
cmd="oc adm release -a '${new_pull_secret}' mirror ${args[*]} | tee '${mirror_output}'"
run_command "$cmd"

line_num=$(grep -n "To use the new mirrored repository for upgrades" "${mirror_output}" | awk -F: '{print $1}')
install_end_line_num=$(expr ${line_num} - 3) &&
upgrade_start_line_num=$(expr ${line_num} + 2) &&
sed -n "/^${regex_keyword_1}/,${install_end_line_num}p" "${mirror_output}" > "${install_config_mirror_patch}"
sed -n "${upgrade_start_line_num},\$p" "${mirror_output}" > "${cluster_mirror_conf_file}"

run_command "cat '${install_config_mirror_patch}'"
rm -f "${new_pull_secret}"
