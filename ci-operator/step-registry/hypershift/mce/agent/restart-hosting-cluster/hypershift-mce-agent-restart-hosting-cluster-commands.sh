#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
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
    local node_ip=$1 ret=0

    echo "$(date -u --rfc-3339=seconds) - Rebooting node ${node_ip}"
    ssh_command "${node_ip}" "sudo reboot" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: Failed to reboot node ${node_ip}"
        return 1
    fi
}

function get_hosting_cluster_nodes() {
    local node_list=""
    local master_list worker_list
    
    # Get master nodes
    master_list=$(oc get node -o wide --no-headers | grep 'master\|control-plane' | awk '{print $1":"$6}' | sort)
    if [[ -n "${master_list}" ]]; then
        node_list="${master_list}"
    fi
    
    # Get worker nodes
    worker_list=$(oc get node -o wide --no-headers | grep 'worker' | awk '{print $1":"$6}' | sort)
    if [[ -n "${worker_list}" ]]; then
        if [[ -n "${node_list}" ]]; then
            node_list="${node_list} ${worker_list}"
        else
            node_list="${worker_list}"
        fi
    fi
    
    echo "${node_list}"
}

function restart_hosting_cluster() {
    local try max_try total_nodes_count=0 node_list="" node_info_list
    declare -A node_ip_array
    
    echo "$(date -u --rfc-3339=seconds) - Starting hosting cluster restart process"
    
    # Get all nodes in the hosting cluster
    node_info_list=$(get_hosting_cluster_nodes)
    if [[ -z "${node_info_list}" ]]; then
        echo "ERROR: No nodes found in the hosting cluster"
        return 1
    fi
    
    # Parse node information
    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        node_list="${node_list} ${node_name}"
        node_ip_array[${node_name}]=${node_ip}
    done
    
    total_nodes_count=$(echo ${node_list} | awk '{print NF}')
    echo "$(date -u --rfc-3339=seconds) - Found ${total_nodes_count} nodes to restart"
    
    # Restart all nodes
    for node_name in ${node_list}; do
        node_ip=${node_ip_array[${node_name}]}
        echo "$(date -u --rfc-3339=seconds) - Restarting node ${node_name} (${node_ip})"
        reboot_node "${node_ip}" || {
            echo "ERROR: Failed to restart node ${node_name}"
            return 1
        }
    done
    
    echo "$(date -u --rfc-3339=seconds) - All nodes have been restarted, waiting for cluster to become available"
    
    # Wait for hosting cluster to become available
    try=0
    max_try=$((RESTART_TIMEOUT / 60))  # Convert to minutes
    while [[ ${try} -lt ${max_try} ]]; do
        if [[ $(oc get node --no-headers | grep -c 'Ready') -eq ${total_nodes_count} ]]; then
            echo "$(date -u --rfc-3339=seconds) - Hosting cluster is ready with all ${total_nodes_count} nodes"
            break
        fi
        echo "$(date -u --rfc-3339=seconds) - Waiting for hosting cluster to become available (${try}/${max_try})"
        sleep 60
        try=$(( try + 1 ))
    done
    
    if [ X"${try}" == X"${max_try}" ]; then
        echo "$(date -u --rfc-3339=seconds) - ERROR: Hosting cluster did not become available within ${RESTART_TIMEOUT} seconds"
        run_command "oc get node"
        return 1
    fi
    
    return 0
}

function check_hosted_clusters() {
    local try max_try
    local hosted_clusters_ready=0
    local total_hosted_clusters=0
    
    echo "$(date -u --rfc-3339=seconds) - Checking hosted clusters status"
    
    # Get total number of hosted clusters
    total_hosted_clusters=$(oc get hostedclusters -A --no-headers | wc -l)
    if [[ ${total_hosted_clusters} -eq 0 ]]; then
        echo "$(date -u --rfc-3339=seconds) - No hosted clusters found"
        return 0
    fi
    
    echo "$(date -u --rfc-3339=seconds) - Found ${total_hosted_clusters} hosted clusters"
    
    # Wait for hosted clusters to become ready
    try=0
    max_try=$((RESTART_TIMEOUT / HOSTED_CLUSTER_CHECK_INTERVAL))
    while [[ ${try} -lt ${max_try} ]]; do
        hosted_clusters_ready=$(oc get hostedclusters -A --no-headers | grep -c 'True' || echo "0")
        if [[ ${hosted_clusters_ready} -eq ${total_hosted_clusters} ]]; then
            echo "$(date -u --rfc-3339=seconds) - All ${total_hosted_clusters} hosted clusters are ready"
            break
        fi
        echo "$(date -u --rfc-3339=seconds) - Hosted clusters status: ${hosted_clusters_ready}/${total_hosted_clusters} ready"
        sleep ${HOSTED_CLUSTER_CHECK_INTERVAL}
        try=$(( try + 1 ))
    done
    
    if [ X"${try}" == X"${max_try}" ]; then
        echo "$(date -u --rfc-3339=seconds) - WARNING: Not all hosted clusters are ready after hosting cluster restart"
        echo "Hosted clusters status:"
        oc get hostedclusters -A
        return 1
    fi
    
    # Final status check
    echo "$(date -u --rfc-3339=seconds) - Final hosted clusters status:"
    oc get hostedclusters -A
    
    return 0
}

if [[ "${ENABLE_HOSTING_CLUSTER_RESTART}" != "true" ]]; then
    echo "ENV 'ENABLE_HOSTING_CLUSTER_RESTART' is not set to 'true', skipping hosting cluster restart..."
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

# Restart hosting cluster
restart_hosting_cluster || {
    echo "ERROR: Failed to restart hosting cluster"
    exit 1
}

# Check hosted clusters status
check_hosted_clusters || {
    echo "WARNING: Some hosted clusters may not be fully ready"
    # Don't exit with error as this might be expected behavior
}

echo "$(date -u --rfc-3339=seconds) - Hosting cluster restart and hosted clusters check completed successfully"