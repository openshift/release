#!/bin/bash

set -e
set -u
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function prepare_tag_images_list () {
    echo "registry.redhat.io/ubi8/ruby-30:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-30:latest
registry.redhat.io/ubi8/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi8/ruby-27:latest
registry.redhat.io/ubi7/ruby-27:latest=MIRROR_REGISTRY_PLACEHOLDER/ubi7/ruby-27:latest
registry.redhat.io/rhscl/ruby-25-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/ruby-25-rhel7:latest
registry.redhat.io/rhscl/mysql-80-rhel7:latest=MIRROR_REGISTRY_PLACEHOLDER/rhscl/mysql-80-rhel7:latest
registry.redhat.io/rhel8/mysql-80:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/mysql-80:latest
registry.redhat.io/rhel8/httpd-24:latest=MIRROR_REGISTRY_PLACEHOLDER/rhel8/httpd-24:latest
" > ${tag_images_list}

    sed -i "s/MIRROR_REGISTRY_PLACEHOLDER/${MIRROR_PROXY_REGISTRY}/g" "${tag_images_list}"
    run_command "cat ${tag_images_list}"
}

run_command "which oc && oc version --client"

pull_secret_filename="new_pull_secret_tag_images"
new_pull_secret="$(mktemp -d)/${pull_secret_filename}"
tag_images_list_filename="tag_images_list"
tag_images_list="$(mktemp -d)/${tag_images_list_filename}"
OC_BIN="oc"

MIRROR_PROXY_REGISTRY=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"
registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
jq --argjson a "{\"${MIRROR_PROXY_REGISTRY}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

args=(
    --insecure=true
    --skip-missing=true
    --skip-verification=true
    --filter-by-os='.*'
)

prepare_tag_images_list

if [[ "${MIRROR_IN_BASTION}" == "yes" ]]; then
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
    remote_pull_secret="/tmp/${pull_secret_filename}"
    remote_tag_images_list="/tmp/${tag_images_list_filename}"
    # shellcheck disable=SC2089
    ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
    remote_oc_bin="/tmp/oc"

    if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "which oc && oc version --client"; then
        echo "use the installed oc in the remote host"
    elif ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "test -x ${remote_oc_bin}"; then
        echo "use the installed oc - ${remote_oc_bin} in the remote host"
        OC_BIN="${remote_oc_bin}"
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

    echo "copy pull secret from local to the remote host"
    # shellcheck disable=SC2090
    scp ${ssh_options} "${new_pull_secret}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_pull_secret}
    args+=(--registry-config="${remote_pull_secret}")

    echo "copy tag images list from local to the remote host"
    # shellcheck disable=SC2090
    scp ${ssh_options} "${tag_images_list}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_tag_images_list}
    args+=(--filename="${remote_tag_images_list}")

    # check whether the oc command supports the extra options and add them to the args array.
    # shellcheck disable=SC2090
    if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} image mirror --help | grep -q -- --keep-manifest-list"; then
        echo "Adding --keep-manifest-list to the mirror command."
        args+=(--keep-manifest-list=true)
    else
        echo "This oc version does not support --keep-manifest-list, skip it."
    fi

    cmd="${OC_BIN} image mirror ${args[*]}"
    echo "Remote Command: ${cmd}"
    # shellcheck disable=SC2090
    ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${cmd}"
else
    args+=(--registry-config="${new_pull_secret}")
    args+=(--filename="${tag_images_list}")
    # check whether the oc command supports the extra options and add them to the args array.
    # shellcheck disable=SC2090
    if ${OC_BIN} image mirror --help | grep -q -- --keep-manifest-list; then
        echo "Adding --keep-manifest-list to the mirror command."
        args+=(--keep-manifest-list=true)
    else
        echo "This oc version does not support --keep-manifest-list, skip it."
    fi
    cmd="${OC_BIN} image mirror ${args[*]}"
    run_command "${cmd}"
fi
