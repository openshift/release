#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function extract_oc_mirror() {
    local pull_secret="$1"
    local release_image="$2"
    local target_dir="$3"
    local image_arch ocp_version ocp_minor_version oc_mirror_image oc_mirror_binary
    echo -e "Extracting oc-mirror\n"
    if [ ! -e "${pull_secret}" ]; then
        echo "[ERROR] pull-secret file ${pull_secret} does not exist"
        return 2
    fi
    if [ -z "${target_dir}" ]; then
        target_dir="."
    fi
    oc_mirror_binary='oc-mirror'
    ocp_version="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${release_image}" --output=json | jq -r '.metadata.version')"
    ocp_minor_version="$(echo "${ocp_version}" | cut -f2 -d.)"
    if (( ocp_minor_version > 15 )) && (openssl version | grep -q "OpenSSL 1") ; then
        oc_mirror_binary='oc-mirror.rhel8'
    fi
    image_arch=$(oc adm release info ${release_image} -a "${pull_secret}" -o jsonpath='{.config.architecture}')
    if [[ "${image_arch}" != "amd64" ]]; then
        echo "The target payload is NOT amd64 arch, trying to find out a matched version of payload image on amd64"
        if [[ -n ${RELEASE_IMAGE_LATEST:-} ]]; then
            release_image=${RELEASE_IMAGE_LATEST}
            echo "Getting release image from RELEASE_IMAGE_LATEST: ${release_image}"
        elif env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc get istag "release:latest" -n ${NAMESPACE} &>/dev/null; then
            release_image=$(env "NO_PROXY=*" "no_proxy=*" "KUBECONFIG=" oc -n ${NAMESPACE} get istag "release:latest" -o jsonpath='{.tag.from.name}')
            echo "Getting release image from build farm imagestream: ${release_image}"
        fi
    fi
    oc_mirror_image=$(oc adm release info -a "${pull_secret}" --image-for='oc-mirror' "$release_image") || return 2
    run_command "oc image extract -a '${pull_secret}' '${oc_mirror_image}' --path /usr/bin/${oc_mirror_binary}:${target_dir} --confirm" || return 2
    if [[ "${oc_mirror_binary}" == "oc-mirror.rhel8" ]]; then
        mv "${target_dir}/oc-mirror.rhel8" "${target_dir}/oc-mirror"
    fi
    ls "${target_dir}/oc-mirror" || return 2
    chmod +x "${target_dir}/oc-mirror" || return 2
    return 0
}

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# target release
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
echo "target_release_image_repo: $target_release_image_repo"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG
oc registry login

readable_version=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
echo "readable_version: $readable_version"
ocp_major_minor=$(echo "${readable_version}" | cut -d '.' -f1,2)
ocp_image_arch=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.config.architecture}')
channel_name="${CHANNEL}-${ocp_major_minor}"
echo "channel_name: $channel_name"

run_command "which oc"
run_command "oc version --client"
oc_mirror_dir=$(mktemp -d)
pushd "${oc_mirror_dir}"
mirror_output="${oc_mirror_dir}/mirror_output"
new_pull_secret="${oc_mirror_dir}/new_pull_secret"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"

# combine custom registry credential and default pull secret
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

# extract oc-mirror from payload image
extract_oc_mirror "${new_pull_secret}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" "${oc_mirror_dir}" || exit 1
oc_mirror_bin="${oc_mirror_dir}/oc-mirror"
run_command "'${oc_mirror_bin}' version --output=yaml"

# pre-check the expected image exists in official channel
if "${oc_mirror_bin}" list releases --filter-by-archs ${ocp_image_arch} --channel=${channel_name} | grep -q "^${readable_version}$"; then
    echo "${readable_version} is found in ${channel_name} on ${ocp_image_arch} arch"
else
    echo "${readable_version} is NOT found in ${channel_name} on ${ocp_image_arch} arch, exit..."
    exit 1
fi

# set the imagesetconfigure
image_set_config="image_set_config.yaml"
cat <<END | tee "${image_set_config}"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
mirror:
  platform:
    architectures:
      - "${ocp_image_arch}"
    channels:
      - name: ${channel_name}
        minVersion: ${readable_version}
        maxVersion: ${readable_version}
END

# https://github.com/openshift/oc-mirror/blob/main/docs/usage.md#authentication
# oc-mirror only respect ~/.docker/config.json -> ${XDG_RUNTIME_DIR}/containers/auth.json
mkdir -p "${XDG_RUNTIME_DIR}/containers/"
cp -rf "${new_pull_secret}" "${XDG_RUNTIME_DIR}/containers/auth.json"

# execute the oc-mirror command
cmd="'${oc_mirror_bin}' -c ${image_set_config} docker://${target_release_image_repo} --dest-skip-tls"
echo "Command: $cmd"
eval "$cmd" | tee "${mirror_output}"

# Get mirror setting for install-config.yaml
result_folder=$(cat "${mirror_output}" | tail -n 1 | awk  '{print $NF}')
icsp_file="${result_folder}/imageContentSourcePolicy.yaml"
mapping_file="${result_folder}/mapping.txt"
if [ ! -f "${icsp_file}" ]; then
    echo "${icsp_file} not found, exit..."
    exit 1
fi
key_name="imageContentSources"
if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    key_name="imageDigestSources"
fi
yq-v4 --prettyPrint eval-all "{\"$key_name\": .spec.repositoryDigestMirrors}" "${icsp_file}" > "${install_config_mirror_patch}" || exit 1
run_command "cp ${mapping_file} ${ARTIFACT_DIR}/mapping.txt"

# Ending
run_command "cat '${install_config_mirror_patch}'"
rm -f "${new_pull_secret}"
