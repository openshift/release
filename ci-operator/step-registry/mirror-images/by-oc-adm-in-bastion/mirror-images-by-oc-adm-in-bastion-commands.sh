#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

mirror_output="${SHARED_DIR}/mirror_output"
pull_secret_filename="new_pull_secret"
new_pull_secret="${SHARED_DIR}/${pull_secret_filename}"
remote_pull_secret="/tmp/${pull_secret_filename}"
install_config_icsp_patch="${SHARED_DIR}/install-config-icsp.yaml.patch"
icsp_file="${SHARED_DIR}/local_registry_icsp_file.yaml"

# private mirror registry host
# <public_dns>:<port>
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

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
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

# shellcheck disable=SC2089
ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
# scp new_pull_secret credential to bastion host
# shellcheck disable=SC2090
scp ${ssh_options} "${new_pull_secret}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_pull_secret}

mirror_options="--insecure=true"
# check whether the oc command supports the --keep-manifest-list and add it to the args array.
# shellcheck disable=SC2090
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "oc adm release mirror -h | grep -q -- --keep-manifest-list"; then
    echo "Adding --keep-manifest-list to the mirror command."
    mirror_options="${mirror_options} --keep-manifest-list=true"
else
    echo "This oc version does not support --keep-manifest-list, skip it."
fi

# mirror images in bastion host, which will increase mirror upload speed
# shellcheck disable=SC2090
ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} \
"oc adm release -a ${remote_pull_secret} mirror ${mirror_options} \
 --from=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} \
 --to=${target_release_image_repo} \
 --to-release-image=${target_release_image}" | tee "${mirror_output}"

grep -B 1 -A 10 "kind: ImageContentSourcePolicy" ${mirror_output} > "${icsp_file}"
grep -A 6 "imageContentSources" ${mirror_output} > "${install_config_icsp_patch}"

echo "${install_config_icsp_patch}:"
cat "${install_config_icsp_patch}"
rm -f "${new_pull_secret}"
