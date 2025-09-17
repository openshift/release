#!/bin/bash

set -o nounset
# set -o errexit  # Disabled to prevent script exit on command failures
set -o pipefail

# Add ERR trap to catch any unexpected exits
trap 'echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Script exited unexpectedly at line $LINENO with exit code $?" >&2; echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stack trace:" >&2; caller >&2; exit 1' ERR

# Add EXIT trap to log script completion
trap 'echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Script completed with exit code $?"' EXIT

# Set AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE="${CLUSTER_PROFILE_DIR}/.aws"

# Set AWS region
export AWS_REGION="${AWS_REGION:-$LEASED_RESOURCE}"

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    # Execute command and capture exit code
    eval "${CMD}"
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        echo "WARNING: Command failed: ${CMD} (exit code: ${exit_code})"
        return ${exit_code}
    fi
}

function print_cluster_diagnostics() {
    local failure_type="$1"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - === CLUSTER DIAGNOSTICS FOR ${failure_type} ==="
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current node status:"
    run_command "oc get nodes -o wide" || true
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current cluster operators status:"
    run_command "oc get clusteroperators" || true
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current etcd status:"
    run_command "oc get etcd -o yaml" || true
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current machine config pools:"
    run_command "oc get machineconfigpools" || true
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current API server status:"
    run_command "oc get apiservers cluster -o yaml" || true
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - === END CLUSTER DIAGNOSTICS ==="
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

    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Getting instance ID for node ${node_name} (${node_ip})"
    
    # Get instance ID from AWS
    # Get instance ID from AWS
    instance_id=$(aws ec2 describe-instances \
        --region "${AWS_REGION:-us-east-1}" \
        --filters "Name=private-ip-address,Values=${node_ip}" \
        --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
        --output text | grep -E '\s+running$' | awk '{print $1}' | head -1)
    aws_exit_code=$?
    
    if [[ ${aws_exit_code} -ne 0 ]]; then
        echo "ERROR: AWS CLI failed to describe instances for IP ${node_ip} (exit code: ${aws_exit_code})"
        return 1
    fi
    
    if [[ -z "${instance_id}" ]]; then
        echo "ERROR: Could not find running instance for IP ${node_ip}"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Found instance ${instance_id} for node ${node_name}"
    
    # Stop the instance
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stopping instance ${instance_id}"
    aws ec2 stop-instances --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: fail to stop instance ${instance_id}"
        return 1
    fi
    
    # Wait for instance to stop
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting for instance ${instance_id} to stop"
    aws ec2 wait instance-stopped --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: instance ${instance_id} did not stop within timeout"
        return 1
    fi
    
    # Start the instance
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Starting instance ${instance_id}"
    aws ec2 start-instances --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: fail to start instance ${instance_id}"
        return 1
    fi
    
    # Wait for instance to start
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting for instance ${instance_id} to start"
    aws ec2 wait instance-running --region "${AWS_REGION:-us-east-1}" --instance-ids "${instance_id}" || ret=1
    if [[ ${ret} == 1 ]]; then
        echo "ERROR: instance ${instance_id} did not start within timeout"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Instance ${instance_id} successfully restarted"
    return 0
}

function reboot_cluster() {
    local try max_try total_nodes_count=0 master_list node_list="" worker_list
    declare -A node_ip_array
    
    # Get node lists with error handling
    master_list=$(oc get node -o wide --no-headers | grep 'master' | awk '{print $1":"$6}' | sort)
    oc_exit_code=$?
    
    if [[ ${oc_exit_code} -ne 0 ]]; then
        echo "ERROR: Failed to get master nodes list (exit code: ${oc_exit_code})"
        return 1
    fi
    
    if [[ "${SIZE_VARIANT}" == "compact" ]]; then
        node_list="${master_list}"
    else
        worker_list=$(oc get node -o wide --no-headers | grep 'worker' | awk '{print $1":"$6}' | sort)
        oc_exit_code=$?
        
        if [[ ${oc_exit_code} -ne 0 ]]; then
            echo "ERROR: Failed to get worker nodes list (exit code: ${oc_exit_code})"
            return 1
        fi
        
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
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - rebooting node ${node_name}, node ip is ${node_ip}"
        if ! reboot_node "${node_ip}" "${node_name}"; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Failed to reboot node ${node_name}, continuing with other nodes..."
        fi
    done

    total_nodes_count=$(echo ${node_list} | awk '{print NF}')
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - All ${total_nodes_count} nodes have been restarted, waiting for cluster to recover..."
    
    # Wait for API server to be accessible first
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting for API server to be accessible..."
    try=0
    max_try=30  # 30 attempts × 30 seconds = 15 minutes
    while [[ ${try} -lt ${max_try} ]]; do
        # Check if API server is accessible
        if oc get nodes --request-timeout=10s >/dev/null 2>&1; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - API server is accessible"
            break
        fi
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - API server not accessible, waiting... (${try}/${max_try})"
        sleep 30
        try=$(( try + 1 ))
    done
    
    if [[ ${try} -eq ${max_try} ]]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: API server not accessible after ${max_try} attempts"
        print_cluster_diagnostics "API SERVER FAILURE"
        return 1
    fi
    
    # Wait for all nodes to be Ready (including Ready,SchedulingDisabled)
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting for all nodes to be Ready..."
    try=0
    max_try=90  # 90 attempts × 60 seconds = 90 minutes
    while [[ ${try} -lt ${max_try} ]]; do
        # Get node status in JSON format to properly parse Ready status
        # Get ready node count
        ready_count=$(oc get nodes -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .metadata.name' 2>/dev/null | wc -l)
        oc_exit_code=$?
        
        if [[ ${oc_exit_code} -ne 0 ]]; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - WARNING: Failed to get node status, retrying..."
            sleep 10
            continue
        fi
        
        if [[ ${ready_count} -eq ${total_nodes_count} ]]; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - All ${total_nodes_count} nodes are Ready"
            break
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ${ready_count}/${total_nodes_count} nodes are Ready, waiting... (${try}/${max_try})"
        sleep 60
        try=$(( try + 1 ))
    done

    if [[ ${try} -eq ${max_try} ]]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Not all nodes are Ready after ${max_try} minutes (1.5 hours)!"
        print_cluster_diagnostics "NODE READY FAILURE"
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Detailed node conditions:"
        run_command "oc get nodes -o json | jq '.items[] | {name: .metadata.name, conditions: .status.conditions[] | select(.type==\"Ready\")}'" || true
        return 1
    fi
    
    # Additional wait for cluster operators to stabilize
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting for cluster operators to stabilize..."
    try=0
    max_try=120  # 120 attempts × 60 seconds = 120 minutes (2 hours) - based on 1 hour cluster recovery time
    consecutive_failures=0
    max_consecutive_failures=10  # Allow up to 10 consecutive failures before giving up
    
    while [[ ${try} -lt ${max_try} ]]; do
        # Check if all cluster operators are Available=True,Progressing=False,Degraded=False
        # Use a more robust approach to count unstable operators
        # Capture both output and error for debugging
        # Get cluster operators status
        clusteroperators_output=$(oc get clusteroperators --no-headers 2>&1)
        oc_exit_code=$?
        
        if [[ ${oc_exit_code} -ne 0 ]]; then
            consecutive_failures=$(( consecutive_failures + 1 ))
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - WARNING: Failed to get cluster operators status (attempt ${consecutive_failures}/${max_consecutive_failures})"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Error details: ${clusteroperators_output}"
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Exit code: ${oc_exit_code}"
            
            if [[ ${consecutive_failures} -ge ${max_consecutive_failures} ]]; then
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Too many consecutive failures getting cluster operators status, giving up"
                print_cluster_diagnostics "COMMAND FAILURE"
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Cluster reboot test failed due to inability to check cluster operators"
                return 1
            fi
            
            sleep 30
            continue
        fi
        
        # Reset consecutive failures counter on successful command
        consecutive_failures=0
        
        # Count unstable operators from successful output
        degraded_ops=$(echo "${clusteroperators_output}" | grep -v "True.*False.*False" | wc -l)
        
        if [[ ${degraded_ops} -eq 0 ]]; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - All cluster operators are stable"
            break
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ${degraded_ops} cluster operators are not stable, waiting... (${try}/${max_try})"
        
        # Show which operators are not stable for debugging
        if [[ ${try} -eq 0 ]] || [[ $((try % 5)) -eq 0 ]]; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current cluster operator status:"
            echo "Running Command: oc get clusteroperators --no-headers | grep -v 'True.*False.*False' || true"
            oc get clusteroperators --no-headers | grep -v 'True.*False.*False' || true
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Debug command completed, continuing..."
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Sleeping for 60 seconds before next check..."
        sleep 60
        try=$(( try + 1 ))
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Starting iteration ${try}/${max_try}"
    done
    
    if [[ ${try} -eq ${max_try} ]]; then
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Some cluster operators are still not stable after ${max_try} minutes (2 hours)"
        print_cluster_diagnostics "CLUSTER OPERATOR FAILURE"
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Unstable cluster operators details:"
        echo "Running Command: oc get clusteroperators --no-headers | grep -v 'True.*False.*False' || true"
        oc get clusteroperators --no-headers | grep -v 'True.*False.*False' || true
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Cluster reboot test failed due to unstable cluster operators"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Cluster reboot test completed successfully"
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

if ! reboot_cluster; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: reboot_cluster function failed"
    exit 1
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - All reboot operations completed successfully"
