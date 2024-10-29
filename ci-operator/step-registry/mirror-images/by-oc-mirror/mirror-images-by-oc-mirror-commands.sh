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

run_command "which oc"
run_command "oc version --client"
oc_mirror_dir=$(mktemp -d)
pushd "${oc_mirror_dir}"
new_pull_secret="${oc_mirror_dir}/new_pull_secret"

# combine custom registry credential and default pull secret
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
cat "${CLUSTER_PROFILE_DIR}/pull-secret" | python3 -c 'import json,sys;j=json.load(sys.stdin);a=j["auths"];a["'${MIRROR_REGISTRY_HOST}'"]={"auth":"'${registry_cred}'"};j["auths"]=a;print(json.dumps(j))' > "${new_pull_secret}"

sleep 3600

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required by oc-mirror since 4.18.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi
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

# execute the oc-mirror command
run_command "'${oc_mirror_bin}' -c ${image_set_config} docker://${target_release_image_repo} --dest-tls-verify=false --v2 --workspace file://${oc_mirror_dir}"

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
