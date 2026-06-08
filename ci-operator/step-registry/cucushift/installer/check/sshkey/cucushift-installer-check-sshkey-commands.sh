#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function ssh_command() {
    local node_ip="$1"
    local node_ssh_private_key=$2
    local node_user=$3
    local cmd="$4"
    local ssh_options ssh_proxy_command="" bastion_ip bastion_ssh_user

    ssh_options="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    if [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
        bastion_ip=$(<"${SHARED_DIR}/bastion_public_address")
        bastion_ssh_user=$(<"${SHARED_DIR}/bastion_ssh_user")
        ssh_proxy_command="-o ProxyCommand='ssh ${ssh_options} -o IdentityFile=${DEFAULT_SSH_PRIV_KEY_PATH} -W %h:%p ${bastion_ssh_user}@${bastion_ip}'"
    fi

    ssh_options="${ssh_options} -o IdentityFile=${node_ssh_private_key}"
    echo "ssh ${ssh_options} ${ssh_proxy_command} ${node_user}@${node_ip} ${cmd}" | sh -
}

function check_ssh_access() {
    local node_info_list=$1
    local node_ssh_private_key=$2 node_user=$3
    local ret_code=0 ret=0

    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        echo "checking on node ${node_name}, node ip is ${node_ip}..."
        cmd="hostname"
        ret=0
        ssh_command "${node_ip}" "${node_ssh_private_key}" "${node_user}" "${cmd}" || ret=1
        if [[ ${ret} -eq 1 ]]; then
            echo "Fail to execute command '${cmd}' on node ${node_name} with user ${node_user}"
            ret_code=1
        else
            echo "Pass to execute command '${cmd}' on node ${node_name} with user ${node_user}"
        fi
    done

    return ${ret_code}
}

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

if [[ -z "${SSH_KEY_TYPE_LIST}" ]]; then
    echo "ENV SSH_KEY_TYPE_LIST is empty, skip the check!"
    exit 0
fi

DEFAULT_SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

check_result=0

node_info_list=$(oc get node -o wide --no-headers | awk '{print $1":"$6}')
SSH_KEY_FILES="${DEFAULT_SSH_PRIV_KEY_PATH}"
for key_type in ${SSH_KEY_TYPE_LIST}; do
    if [[ -f "${SHARED_DIR}/key-${key_type}" ]]; then
        chmod 600 "${SHARED_DIR}/key-${key_type}"
        SSH_KEY_FILES="${SSH_KEY_FILES} ${SHARED_DIR}/key-${key_type}"
    else
        echo "ERROR: could not find private sshkey for key type '${key_type}' in '${SHARED_DIR}'!"
        exit 1
    fi
done

for key_file in ${SSH_KEY_FILES}; do
    echo -e "\n------ Check ssh key ${key_file} on all nodes ------"
    echo "checking on user 'core'..."
    if check_ssh_access "${node_info_list}" "${key_file}" "core"; then
        echo "INFO: check passed for ssh key ${key_file} with user core!"
    else
        echo "ERROR: check failed for ssh key ${key_file} with user core!"
        check_result=1
    fi
    echo -e "\nchecking on user 'root'..."
    if check_ssh_access "${node_info_list}" "${key_file}" "root"; then
        echo "ERROR: check failed for ssh key ${key_file} with user root, should not login"
        check_result=1
    else
        echo "INFO: check passed for ssh key ${key_file} with user root"
    fi
done

exit ${check_result}
