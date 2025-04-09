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

if [[ "${MIRROR_IN_BASTION}" != "yes" ]]; then
  echo "users are going to mirror images from local, skip this step."
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
pull_secret_filename="new_pull_secret"
new_pull_secret="${SHARED_DIR}/${pull_secret_filename}"
remote_pull_secret="/tmp/${pull_secret_filename}"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
cluster_mirror_conf_file="${SHARED_DIR}/local_registry_mirror_file.yaml"

# private mirror registry host
# <public_dns>:<port>
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

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
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"
oc registry login --to "${new_pull_secret}"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
if [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
    BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
fi
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

# shellcheck disable=SC2089
ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
echo "copy pull secret from local to the remote host"
# shellcheck disable=SC2090
scp ${ssh_options} "${new_pull_secret}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_pull_secret}

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

run_command "which oc && oc version --client"
OC_BIN="oc"
remote_oc_bin="/tmp/oc"
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "which oc && oc version --client"; then
    echo "use the installed oc in the remote host"
else
    local_oc_bin=$(which oc)
    echo "copy ${local_oc_bin} from local to the remote host"
    # shellcheck disable=SC2090
    scp ${ssh_options} "${local_oc_bin}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_oc_bin}
    OC_BIN="${remote_oc_bin}"
    # Note, if hit "/lib64/libc.so.6: version `GLIBC_2.33' not found" issue, that means the
    # remote host OS is out of date, maybe need to use a newer bastion image to launch.
    ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} version --client"
fi

# check whether the oc command supports the extra options and add them to the args array.
# shellcheck disable=SC2090
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} adm release mirror -h | grep -q -- --keep-manifest-list"; then
    echo "Adding --keep-manifest-list to the mirror command."
    args+=(--keep-manifest-list=true)
else
    echo "This oc version does not support --keep-manifest-list, skip it."
fi

# shellcheck disable=SC2090
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} adm release mirror -h | grep -q -- --print-mirror-instructions"; then
    echo "Adding --print-mirror-instructions to the mirror command."
    args+=(--print-mirror-instructions="${mirror_crd_type}")
else
    echo "This oc version does not support --print-mirror-instructions, skip it."
fi

# mirror images in bastion host, which will increase mirror upload speed
cmd="${OC_BIN} adm release -a '${remote_pull_secret}' mirror ${args[*]}"
echo "Remote Command: ${cmd}"
# shellcheck disable=SC2090
ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} \
"${cmd}" | tee "${mirror_output}"

line_num=$(grep -n "To use the new mirrored repository for upgrades" "${mirror_output}" | awk -F: '{print $1}')
install_end_line_num=$(expr ${line_num} - 3) &&
upgrade_start_line_num=$(expr ${line_num} + 2) &&
sed -n "/^${regex_keyword_1}/,${install_end_line_num}p" "${mirror_output}" > "${install_config_mirror_patch}"
sed -n "${upgrade_start_line_num},\$p" "${mirror_output}" > "${cluster_mirror_conf_file}"

run_command "cat '${install_config_mirror_patch}'"
rm -f "${new_pull_secret}"
