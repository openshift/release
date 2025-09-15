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
    local node_ip=$1 node_name=$2 ret=0
    local instance_id

    echo "$(date -u --rfc-3339=seconds) - Getting instance ID for node ${node_name} (${node_ip})"
    
    # Get instance ID from AWS
    instance_id=$(aws ec2 describe-instances \
        --region "${AWS_REGION:-us-east-1}" \
        --filters "Name=private-ip-address,Values=${node_ip}" \
        --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
        --output text | grep -E '\s+running$' | awk '{print $1}' | head -1)
    
    if [[ -z "${instance_id}" ]]; then
        echo "ERROR: Could not find running instance for IP ${node_ip}"
        return 1
    fi
    
    echo "$(date -u --rfc-3339=seconds) - Found instance ${instance_id} for node ${node_name}"
    
    # Stop the instance
    echo "$(date -u --rfc-3339=seconds) - Stopping instance ${instance_id}"
    aws ec2 stop-instances --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: fail to stop instance ${instance_id}"
        return 1
    fi
    
    # Wait for instance to stop
    echo "$(date -u --rfc-3339=seconds) - Waiting for instance ${instance_id} to stop"
    aws ec2 wait instance-stopped --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: instance ${instance_id} did not stop within timeout"
        return 1
    fi
    
    # Start the instance
    echo "$(date -u --rfc-3339=seconds) - Starting instance ${instance_id}"
    aws ec2 start-instances --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: fail to start instance ${instance_id}"
        return 1
    fi
    
    # Wait for instance to start
    echo "$(date -u --rfc-3339=seconds) - Waiting for instance ${instance_id} to start"
    aws ec2 wait instance-running --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: instance ${instance_id} did not start within timeout"
        return 1
    fi
    
    echo "$(date -u --rfc-3339=seconds) - Instance ${instance_id} successfully restarted"
    return 0
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

    for node_name in ${node_list}; do
        node_ip=${node_ip_array[${node_name}]}
        echo "$(date -u --rfc-3339=seconds) - rebooting node ${node_name}, node ip is ${node_ip}"
        reboot_node "${node_ip}" "${node_name}"
    done

    total_nodes_count=$(echo ${node_list} | awk '{print NF}')
    echo "$(date -u --rfc-3339=seconds) - All ${total_nodes_count} nodes have been restarted, waiting for cluster to recover..."
    
    # Wait for API server to be accessible first
    echo "$(date -u --rfc-3339=seconds) - Waiting for API server to be accessible..."
    try=0
    max_try=20
    while [[ ${try} -lt ${max_try} ]]; do
        if oc get nodes --request-timeout=10s >/dev/null 2>&1; then
            echo "$(date -u --rfc-3339=seconds) - API server is accessible"
            break
        fi
        echo "$(date -u --rfc-3339=seconds) - API server not accessible, waiting... (${try}/${max_try})"
        sleep 30
        try=$(( try + 1 ))
    done
    
    if [[ ${try} -eq ${max_try} ]]; then
        echo "$(date -u --rfc-3339=seconds) - ERROR: API server not accessible after ${max_try} attempts"
        return 1
    fi
    
    # Wait for all nodes to be Ready (including Ready,SchedulingDisabled)
    echo "$(date -u --rfc-3339=seconds) - Waiting for all nodes to be Ready..."
    try=0
    max_try=60  # 60 minutes total
    while [[ ${try} -lt ${max_try} ]]; do
        # Get node status in JSON format to properly parse Ready status
        ready_count=$(oc get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .metadata.name' | wc -l)
        
        if [[ ${ready_count} -eq ${total_nodes_count} ]]; then
            echo "$(date -u --rfc-3339=seconds) - All ${total_nodes_count} nodes are Ready"
            break
        fi
        
        echo "$(date -u --rfc-3339=seconds) - ${ready_count}/${total_nodes_count} nodes are Ready, waiting... (${try}/${max_try})"
        sleep 60
        try=$(( try + 1 ))
    done

    if [[ ${try} -eq ${max_try} ]]; then
        echo "$(date -u --rfc-3339=seconds) - ERROR: Not all nodes are Ready after ${max_try} minutes!"
        run_command "oc get nodes -o wide"
        run_command "oc get nodes -o json | jq '.items[] | {name: .metadata.name, conditions: .status.conditions[] | select(.type==\"Ready\")}'"
        return 1
    fi
    
    # Additional wait for cluster operators to stabilize
    echo "$(date -u --rfc-3339=seconds) - Waiting for cluster operators to stabilize..."
    try=0
    max_try=30  # 30 minutes
    while [[ ${try} -lt ${max_try} ]]; do
        # Check if all cluster operators are Available=True,Progressing=False,Degraded=False
        degraded_ops=$(oc get clusteroperators --no-headers | grep -v "True.*False.*False" | wc -l)
        
        if [[ ${degraded_ops} -eq 0 ]]; then
            echo "$(date -u --rfc-3339=seconds) - All cluster operators are stable"
            break
        fi
        
        echo "$(date -u --rfc-3339=seconds) - ${degraded_ops} cluster operators are not stable, waiting... (${try}/${max_try})"
        sleep 60
        try=$(( try + 1 ))
    done
    
    if [[ ${try} -eq ${max_try} ]]; then
        echo "$(date -u --rfc-3339=seconds) - WARNING: Some cluster operators are still not stable after ${max_try} minutes"
        run_command "oc get clusteroperators"
    fi
    
    echo "$(date -u --rfc-3339=seconds) - Cluster reboot test completed successfully"
    return 0
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
