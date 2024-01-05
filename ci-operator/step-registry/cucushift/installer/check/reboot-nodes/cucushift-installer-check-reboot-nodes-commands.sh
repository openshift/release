#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function run_command_with_retries()
{
    local try=0 cmd="$1" retries="${2:-}" ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}'"

    eval "${cmd}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$(( try + 1))
        ret=0
        eval "${cmd}" || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
}

function ssh_command() {
    local node_ip="$1"
    local cmd="$2"
    local ssh_options ssh_proxy_command="" bastion_ip bastion_ssh_user

    ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
    if [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
        bastion_ip=$(<"${SHARED_DIR}/bastion_public_address")
        bastion_ssh_user=$(<"${SHARED_DIR}/bastion_ssh_user")
        ssh_proxy_command="-o ProxyCommand='ssh ${ssh_options} -W %h:%p ${bastion_ssh_user}@${bastion_ip}'"
    fi

    echo "ssh ${ssh_options} ${ssh_proxy_command} core@${node_ip} '${cmd}'" | sh -
}

function reboot_node() {
    local node_ip=$1 reboot_number_before reboot_number_after ret=0

    reboot_number_before=$(ssh_command "${node_ip}" "last | grep -c reboot")

    ssh_command "${node_ip}" "sudo reboot" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: fail to reboot vm instance ${node_ip}"
        return 1
    fi

    # wait for node restarting
    # add some sleep between node reboot to avoid etcd cluster can not record reboot event
    sleep 120

    # check if node has been restarted and can be ssh access
    echo "after sleeping 2min, check node can be access..."
    cmd="ssh_command '${node_ip}' 'hostname'"
    run_command_with_retries "${cmd}" "5"

    reboot_number_after=$(ssh_command "${node_ip}" "last | grep -c reboot")

    if [[ $(( reboot_number_after - reboot_number_before )) -ge 1 ]]; then
        echo "INFO: succeed to reboot vm instance ${node_ip}"
        return 0
    else
        echo "ERROR: fail to reboot vm instance ${node_ip}"
        echo "DEBUG: reboot_number_before: ${reboot_number_before}, reboot_number_after: ${reboot_number_after}"
        return 1
    fi
}

function reboot_cluster() {
    local try max_try total_nodes_count=0 master_list node_list="" worker_list
    declare -A node_ip_array
    master_list=$(oc get node -o wide --no-headers | grep 'master' | awk '{print $1":"$6}' | sort)
    if [[ "${SIZE_VARIANT}" == "compact" ]]; then
        node_list="${master_list}"
    else
        worker_list=$(oc get node -o wide --no-headers | grep 'worker' | awk '{print $1":"$6}' | sort)
        node_info_list="${worker_list} ${master_list}"
    fi
    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        node_list="${node_list} ${node_name}"
        node_ip_array[${node_name}]=${node_ip}
    done

    echo "$(date -u --rfc-3339=seconds) - rebooted events before rebooting all node:"
    run_command "oc get events -n default | grep 'Rebooted'" || true
    for node_name in ${node_list}; do
        node_ip=${node_ip_array[${node_name}]}
        echo "$(date -u --rfc-3339=seconds) - rebooting node ${node_name}, node ip is ${node_ip}"
        reboot_node "${node_ip}"
    done

    total_nodes_count=$(echo ${node_list} | awk '{print NF}')
    try=0
    max_try=6
    while [[ ${try} -lt ${max_try} ]]; do
	if [[ $(oc get node --no-headers | grep -c 'Ready') -eq ${total_nodes_count} ]]; then
            echo "$(date -u --rfc-3339=seconds) - cluster boot up, get ready"
            break
        fi
        echo "$(date -u --rfc-3339=seconds) - wait for node boot up"
        sleep 60
        try=$(( try + 1 ))
    done

    echo "$(date -u --rfc-3339=seconds) - rebooted events after rebooting all node:"
    run_command "oc get events -n default | grep 'Rebooted'" || true
    if [ X"${try}" == X"${max_try}" ]; then
	echo "$(date -u --rfc-3339=seconds) - ERROR: some nodes are not ready!"
        run_command "oc get node"
        return 1
    else
        return 0
    fi
}

if [[ "${ENABLE_REBOOT_CHECK}" != "true" ]]; then
    echo "ENV 'ENABLE_REBOOT_CHECK' is not set to 'true', skip the operation of rebooting nodes..."
    exit 0
fi

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

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

reboot_cluster
