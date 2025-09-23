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

if [[ "${MIRROR_BIN}" != "oc-mirror" ]]; then
  echo "users specifically do not use oc-mirror to run mirror"
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

#"oc-mirror --v2 version" return "v0.0.0-unknown" in < ocp 4.18
#oc major version is same with the oc-mirror major version,
#use oc version to check the oc-mirror version
function isPreVersion() {
  local required_ocp_version="$1"
  local isPre version
  #version=$(${oc_mirror_bin} version --output json | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["clientVersion"]["gitVersion"])' | cut -d '.' -f1,2)
  version=$(oc version -o json |  python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["clientVersion"]["gitVersion"])' | cut -d '.' -f1,2)
  echo "get oc version: ${version}"
  isPre=0
  if [ -n "${version}" ] && [ "$(printf '%s\n' "${required_ocp_version}" "${version}" | sort --version-sort | head -n1)" = "${required_ocp_version}" ]; then
    isPre=1
  fi
  return $isPre
}

function check_signed() {
    local digest algorithm hash_value response try max_retries payload="${1}"
    if [[ "${payload}" =~ "@sha256:" ]]; then
        digest="$(echo "${payload}" | cut -f2 -d@)"
        echo "The target image is using digest pullspec, its digest is ${digest}"
    else
        digest="$(oc image info "${payload}" -o json | python3 -c 'import json,sys;j=json.load(sys.stdin);print(j["digest"])')"
        echo "The target image is using tagname pullspec, its digest is ${digest}"
    fi
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    try=0
    max_retries=3
    response=0
    while (( try < max_retries && response != 200 )); do
        echo "Trying #${try}"
        response=$(https_proxy="" HTTPS_PROXY="" curl -L --silent --output /dev/null --write-out %"{http_code}" "https://mirror.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
        (( try += 1 ))
        sleep 60
    done
    if (( response == 200 )); then
        echo "${payload} is signed" && return 0
    else
        echo "Seem like ${payload} is not signed" && return 1
    fi
}

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

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

run_command "which oc"
run_command "oc version --client"
oc_mirror_dir=$(mktemp -d)
pushd "${oc_mirror_dir}"
new_pull_secret="${oc_mirror_dir}/new_pull_secret"

# combine custom registry credential and default pull secret
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
cat "${CLUSTER_PROFILE_DIR}/pull-secret" | python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${MIRROR_REGISTRY_HOST}'"]={"auth":"'${registry_cred}'"};j["auths"]=a;print(json.dumps(j))' > "${new_pull_secret}"
oc registry login --to "${new_pull_secret}"

# This is required by oc-mirror since 4.18, refer to OCPBUGS-43986.
#if ! whoami &> /dev/null; then
#    user_name=$(id -u)
#else
#    user_name=$(whoami)
#fi
#for file in /etc/subuid /etc/subgid; do
#    if grep -q "$user_name" $file; then
#        echo "$user_name is already set in $file"
#    else
#        last_line=$(tail -1 $file)
#        if [[ -n "$last_line" ]]; then
#            n=$(echo "$last_line" | awk -F: '{print $2}')
#            m=$(echo "$last_line" | awk -F: '{print $3}')
#            start_id=$((n + m))
#        else
#            echo "no any existing users in $file"
#            start_id="100000"
#        fi
#        if [[ -w $file ]]; then
#            echo "${user_name}:${start_id}:65536" >> $file
#            echo "successfully updated $file"
#        else
#            echo "$file is not writeable, and user matching this uid is not found."
#            exit 1
#        fi
#    fi
#done

oc_mirror_bin="oc-mirror"
run_command "'${oc_mirror_bin}' version --output=yaml"


# set the imagesetconfigure
image_set_config="image_set_config.yaml"
cat <<END | tee "${image_set_config}"
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
END

# https://github.com/openshift/oc-mirror/blob/main/docs/usage.md#authentication
# oc-mirror only respect ~/.docker/config.json -> ${XDG_RUNTIME_DIR}/containers/auth.json
mkdir -p "${XDG_RUNTIME_DIR}/containers/"
cp -rf "${new_pull_secret}" "${XDG_RUNTIME_DIR}/containers/auth.json"

unset REGISTRY_AUTH_PREFERENCE

mirrorCmd="${oc_mirror_bin} -c ${image_set_config} docker://${target_release_image_repo} --dest-tls-verify=false --v2 --workspace file://${oc_mirror_dir}"

# ref OCPBUGS-56009
if ! isPreVersion "4.19" && ! check_signed "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" ; then
    mirrorCmd="${mirrorCmd} --ignore-release-signature"
fi
# execute the oc-mirror command
run_command "${mirrorCmd}"

# Save output from oc-mirror
result_folder="${oc_mirror_dir}/working-dir"
idms_file="${result_folder}/cluster-resources/idms-oc-mirror.yaml"
itms_file="${result_folder}/cluster-resources/itms-oc-mirror.yaml"

if [ ! -s "${idms_file}" ]; then
    echo "${idms_file} not found, exit..."
    exit 1
else
    run_command "cat '${idms_file}'"
    run_command "cp -rf '${idms_file}' ${SHARED_DIR}"
fi

if [ -s "${itms_file}" ]; then
    echo "${itms_file} found"
    run_command "cat '${itms_file}'"
    run_command "cp -rf '${itms_file}' ${SHARED_DIR}"
fi

# Ending
rm -f "${new_pull_secret}"
