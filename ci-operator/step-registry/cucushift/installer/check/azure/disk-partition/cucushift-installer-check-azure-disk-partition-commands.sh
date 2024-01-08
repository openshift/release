#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function ssh_command() {
    local node_ip="$1"
    local cmd="$2"
    local ssh_options ssh_proxy_command bastion_ip bastion_ssh_user ssh_proxy_command=""

    ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
    if [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
        bastion_ip=$(<"${SHARED_DIR}/bastion_public_address")
        bastion_ssh_user=$(<"${SHARED_DIR}/bastion_ssh_user")
        ssh_proxy_command="-o ProxyCommand='ssh ${ssh_options} -W %h:%p ${bastion_ssh_user}@${bastion_ip}'"
    fi

    echo "ssh ${ssh_options} ${ssh_proxy_command} core@${node_ip} ${cmd}" | sh -
}

function check_disk_partition_on_node() {

    local node_info_list=$1 path=$2 expected_disk_size=$3
    local node_name node_ip partition_check_code=0

    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        echo -e "\n----- checking node ${node_name} -----"

        echo "checking block devices disk size..."
        block_device_info=$(mktemp)
        cmd="lsblk -J | jq -r '.blockdevices[] | select (.size==\"${expected_disk_size}\")'"
        ret_cmd=0
        ssh_command "${node_ip}" "${cmd}" > ${block_device_info} || ret_cmd=1
        if [[ ${ret_cmd} -eq 0 ]] && [[ -s "${block_device_info}" ]]; then
            echo "INFO: get block devices with expected disk size ${expected_disk_size}!"
            cat "${block_device_info}"

            # check mount point
            echo "checking mount point..."
            path_result=""
            path_result=$(cat "${block_device_info}" | jq -r ".children[] | select(.mountpoints[] | endswith(\"${path}\"))")
            if [[ -n "${path_result}" ]]; then
                echo -e "INFO: get expected mount point ${path}!\n${path_result}"
            else
                echo "ERROR: fail to get expected mount point ${path}!"
                partition_check_code=1
            fi
        else
            echo "ERROR: could not find the block devices with expected disk size ${expected_disk_size}!"
            partition_check_code=1
        fi

        echo "checking logical device /dev/disk/by-partlabel/data01 ..."
        cmd="ls /dev/disk/by-partlabel/data01"
        ret_cmd=0
        ssh_command "${node_ip}" "${cmd}" || ret_cmd=1
        if [[ ${ret_cmd} -eq 1 ]]; then
            echo "ERROR: could not find logical device!"
            partition_check_code=1
        else
            echo "INFO: succeed to find logical device!"
        fi
    done

    return ${partition_check_code}
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

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

check_result=0

master_disk_info="${SHARED_DIR}/azure_master_new_disk_info"
if [[ -f "${master_disk_info}" ]]; then
    path="$(cat "${master_disk_info}" | jq -r '.path')"
    disk_size="$(cat "${master_disk_info}" | jq -r '.disk_size')"
    master_info_list=$(oc get node -o wide --no-headers | grep 'master' | awk '{print $1":"$6}')
    check_disk_partition_on_node "${master_info_list}" "${path}" "${disk_size}G" || check_result=1
fi

worker_disk_info="${SHARED_DIR}/azure_worker_new_disk_info"
if [[ -f "${worker_disk_info}" ]]; then
    path="$(cat "${worker_disk_info}" | jq -r '.path')"
    disk_size="$(cat "${worker_disk_info}" | jq -r '.disk_size')"
    worker_info_list=$(oc get node -o wide --no-headers | grep 'worker' | awk '{print $1":"$6}')
    check_disk_partition_on_node "${worker_info_list}" "${path}" "${disk_size}G" || check_result=1
fi

exit ${check_result}
