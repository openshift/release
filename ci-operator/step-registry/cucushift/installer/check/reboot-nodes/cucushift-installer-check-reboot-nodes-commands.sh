#!/bin/bash

set -o nounset
# set -o errexit  # Disabled to prevent script exit on command failures
set -o pipefail

# Enhanced error handling function
error_handler() {
    local exit_code=$?
    local line_number=$1
    local command="$2"
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ==========================================" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Script failed unexpectedly!" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ==========================================" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Exit code: ${exit_code}" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Line number: ${line_number}" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Failed command: ${command}" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current working directory: $(pwd)" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current user: $(whoami)" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Process ID: $$" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Parent process ID: $PPID" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Shell options: $-" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ==========================================" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stack trace:" >&2
    local frame=0
    while caller $frame; do
        ((frame++))
    done >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ==========================================" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Environment variables:" >&2
    env | grep -E "(CLUSTER|AWS|KUBE|OPENSHIFT)" | sort >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ==========================================" >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Recent command history:" >&2
    history | tail -10 >&2
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ==========================================" >&2
    exit 1
}

# Add ERR trap to catch any unexpected exits
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

# Enhanced exit handler
exit_handler() {
    local exit_code=$?
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Script execution completed"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Final exit code: ${exit_code}"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Execution time: $((SECONDS)) seconds"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
}

# Add EXIT trap to log script completion
trap 'exit_handler' EXIT

# Configuration constants - Reduced timeouts based on test results
readonly API_SERVER_TIMEOUT=20      # 20 attempts × 30 seconds = 10 minutes
readonly NODE_READY_TIMEOUT=60      # 60 attempts × 60 seconds = 60 minutes
readonly CLUSTER_OPERATOR_TIMEOUT=90   # 90 attempts × 60 seconds = 90 minutes
readonly CLUSTER_OPERATOR_STABLE_PATTERN="True.*False.*False"

# Reboot strategy configuration
# SEQUENTIAL: Stop first node, wait for it to be running, then move to next (current default)
# BATCH_STOP_START: Stop all nodes at once, wait fixed time, then start them one by one
readonly REBOOT_STRATEGY="${REBOOT_STRATEGY:-SEQUENTIAL}"

# Record script start time for execution time calculation
SECONDS=0
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Script execution started"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Script: $0"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Arguments: $*"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Process ID: $$"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Working directory: $(pwd)"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - User: $(whoami)"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="

# Platform detection and AWS-specific setup
if [[ "${CLUSTER_TYPE}" == "aws" ]]; then
    # Set AWS credentials only for AWS platform
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    export AWS_CONFIG_FILE="${CLUSTER_PROFILE_DIR}/.aws"
    export AWS_REGION="${AWS_REGION:-$LEASED_RESOURCE}"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - AWS platform detected, AWS CLI configured"
else
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Non-AWS platform detected (${CLUSTER_TYPE}), using SSH-based reboot"
fi

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    # Execute command and capture both output and exit code
    local output
    output=$(eval "${CMD}" 2>&1)
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        echo "WARNING: Command failed: ${CMD} (exit code: ${exit_code})"
        echo "Output: ${output}"
        return ${exit_code}
    fi
    
    # Return the output for command substitution
    echo "${output}"
}

function run_command_silent() {
    local CMD="$1"
    # Execute command silently and return output for command substitution
    eval "${CMD}" 2>/dev/null || echo ""
}

function wait_for_condition() {
    local condition_name="$1"
    local check_command="$2"
    local max_attempts="$3"
    local sleep_interval="$4"
    local failure_message="$5"
    local show_status_command="$6"  # Optional command to show status (both during waiting and on success)
    
    local attempt=0
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting for ${condition_name}..."
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if eval "${check_command}"; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ${condition_name} condition met"
            
            # Show success details if command provided
            if [[ -n "${show_status_command}" ]]; then
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ${condition_name} success details:"
                eval "${show_status_command}" || true
            fi
            
            return 0
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ${condition_name} not ready, waiting... (${attempt}/${max_attempts})"
        
        # Show current status if command provided and at specific intervals
        if [[ -n "${show_status_command}" ]] && [[ ${attempt} -eq 0 ]] || [[ $((attempt % 5)) -eq 0 ]]; then
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Current ${condition_name} status:"
            eval "${show_status_command}" || true
        fi
        
        sleep "${sleep_interval}"
        attempt=$(( attempt + 1 ))
    done
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: ${failure_message}"
    return 1
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
    local node_ip=$1 node_name=$2
    
    if [[ "${CLUSTER_TYPE}" == "aws" ]]; then
        # AWS platform: Use EC2 stop/start for more reliable reboot
        local instance_id
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Getting instance ID for node ${node_name} (${node_ip})"
        
        # Get instance ID from AWS using run_command for consistent error handling
        local describe_cmd="aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --filters 'Name=private-ip-address,Values=${node_ip}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text | grep -E '\\s+running$' | awk '{print \$1}' | head -1"
        instance_id=$(run_command_silent "${describe_cmd}")
        
        if [[ -z "${instance_id}" ]]; then
            echo "ERROR: Could not find running instance for IP ${node_ip}"
            return 1
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Found instance ${instance_id} for node ${node_name}"
        
        # Stop the instance
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stopping instance ${instance_id}"
        if ! run_command "aws ec2 stop-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}'"; then
            echo "ERROR: Failed to stop instance ${instance_id}"
            return 1
        fi
        
        # Wait for instance to stop using wait_for_condition
        if ! wait_for_condition "instance ${instance_id} to stop" \
            "aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}' --query 'Reservations[*].Instances[*].State.Name' --output text | grep -q 'stopped'" \
            20 10 \
            "Instance ${instance_id} did not stop within 3.5 minutes" \
            "aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text"; then
            return 1
        fi
        
        # Start the instance
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Starting instance ${instance_id}"
        if ! run_command "aws ec2 start-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}'"; then
            echo "ERROR: Failed to start instance ${instance_id}"
            return 1
        fi
        
        # Wait for instance to start using wait_for_condition
        if ! wait_for_condition "instance ${instance_id} to start" \
            "aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}' --query 'Reservations[*].Instances[*].State.Name' --output text | grep -q 'running'" \
            20 10 \
            "Instance ${instance_id} did not start within 3.5 minutes" \
            "aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text"; then
            return 1
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Instance ${instance_id} successfully restarted"
    else
        # Non-AWS platform: Use SSH-based reboot
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Using SSH-based reboot for ${node_name} (${node_ip})"
        if ! ssh_command "${node_ip}" "sudo reboot"; then
            echo "ERROR: Failed to reboot node ${node_name} via SSH"
            return 1
        fi
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - SSH reboot command sent to ${node_name}"
    fi
    
    return 0
}

function reboot_node_stop_only() {
    local node_ip=$1 node_name=$2
    local instance_id
    
    if [[ "${CLUSTER_TYPE}" != "aws" ]]; then
        echo "ERROR: BATCH_STOP_START strategy only supported on AWS platform"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Getting instance ID for node ${node_name} (${node_ip})"
    
    local describe_cmd="aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --filters 'Name=private-ip-address,Values=${node_ip}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text | grep -E '\\s+running$' | awk '{print \$1}' | head -1"
    instance_id=$(run_command_silent "${describe_cmd}")
    
    if [[ -z "${instance_id}" ]]; then
        echo "ERROR: Could not find running instance for IP ${node_ip}"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stopping instance ${instance_id} for node ${node_name}"
    if ! run_command "aws ec2 stop-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}'"; then
        echo "ERROR: Failed to stop instance ${instance_id}"
        return 1
    fi
    
    return 0
}

function reboot_node_start_only() {
    local node_ip=$1 node_name=$2
    local instance_id
    
    if [[ "${CLUSTER_TYPE}" != "aws" ]]; then
        echo "ERROR: BATCH_STOP_START strategy only supported on AWS platform"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Getting instance ID for node ${node_name} (${node_ip})"
    
    local describe_cmd="aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --filters 'Name=private-ip-address,Values=${node_ip}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text | grep -E '\\s+stopped$' | awk '{print \$1}' | head -1"
    instance_id=$(run_command_silent "${describe_cmd}")
    
    if [[ -z "${instance_id}" ]]; then
        echo "ERROR: Could not find stopped instance for IP ${node_ip}"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Starting instance ${instance_id} for node ${node_name}"
    if ! run_command "aws ec2 start-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}'"; then
        echo "ERROR: Failed to start instance ${instance_id}"
        return 1
    fi
    
    # Wait for instance to start using wait_for_condition
    if ! wait_for_condition "instance ${instance_id} to start" \
        "aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}' --query 'Reservations[*].Instances[*].State.Name' --output text | grep -q 'running'" \
        20 10 \
        "Instance ${instance_id} did not start within 3.5 minutes" \
        "aws ec2 describe-instances --region '${AWS_REGION:-us-east-1}' --instance-ids '${instance_id}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text"; then
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Instance ${instance_id} successfully started"
    return 0
}

function reboot_cluster() {
    local total_nodes_count=0 master_list node_list="" worker_list
    declare -A node_ip_array
    
    # Get node lists with error handling
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Getting master nodes list..."
    master_list=$(run_command_silent "oc get node -o wide --no-headers | grep 'master' | awk '{print \$1\":\"\$6}' | sort")
    
    if [[ -z "${master_list}" ]]; then
        echo "ERROR: Failed to get master nodes list or no master nodes found"
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Found master nodes: ${master_list}"
    
    if [[ "${SIZE_VARIANT}" == "compact" ]]; then
        node_list="${master_list}"
    else
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Getting worker nodes list..."
        worker_list=$(run_command_silent "oc get node -o wide --no-headers | grep 'worker' | awk '{print \$1\":\"\$6}' | sort")
        
        if [[ -z "${worker_list}" ]]; then
            echo "ERROR: Failed to get worker nodes list or no worker nodes found"
            return 1
        fi
        
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Found worker nodes: ${worker_list}"
        
        node_info_list="${worker_list} ${master_list}"
    fi
    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        node_list="${node_list} ${node_name}"
        node_ip_array[${node_name}]=${node_ip}
    done

    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Using reboot strategy: ${REBOOT_STRATEGY}"
    
    if [[ "${REBOOT_STRATEGY}" == "BATCH_STOP_START" && "${CLUSTER_TYPE}" == "aws" ]]; then
        # Batch stop all nodes first
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Batch stopping all nodes..."
        for node_name in ${node_list}; do
            node_ip=${node_ip_array[${node_name}]}
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Stopping node ${node_name} (${node_ip})"
            if ! reboot_node_stop_only "${node_ip}" "${node_name}"; then
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Failed to stop node ${node_name}, continuing with other nodes..."
            fi
        done
        
        # Wait fixed time for all nodes to stop
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Waiting 2 minutes for all nodes to stop completely..."
        sleep 120
        
        # Start all nodes one by one
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Starting all nodes..."
        for node_name in ${node_list}; do
            node_ip=${node_ip_array[${node_name}]}
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Starting node ${node_name} (${node_ip})"
            if ! reboot_node_start_only "${node_ip}" "${node_name}"; then
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Failed to start node ${node_name}, continuing with other nodes..."
            fi
        done
    else
        # Sequential reboot (default behavior)
        for node_name in ${node_list}; do
            node_ip=${node_ip_array[${node_name}]}
            echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - rebooting node ${node_name}, node ip is ${node_ip}"
            if ! reboot_node "${node_ip}" "${node_name}"; then
                echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: Failed to reboot node ${node_name}, continuing with other nodes..."
            fi
        done
    fi

           total_nodes_count=$(echo "${node_list}" | awk '{print NF}' 2>/dev/null | tr -d '\n' || echo "0")
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Total nodes to reboot: ${total_nodes_count}"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - All ${total_nodes_count} nodes have been restarted, waiting for cluster to recover..."
    
    # Wait for API server to be accessible first
    if ! wait_for_condition "API server accessibility" \
        "oc get nodes --request-timeout=10s >/dev/null 2>&1" \
        "${API_SERVER_TIMEOUT}" 30 \
        "API server not accessible after ${API_SERVER_TIMEOUT} attempts" \
        "oc get nodes --request-timeout=10s | head -5"; then
        print_cluster_diagnostics "API SERVER FAILURE"
        return 1
    fi
    
    # Wait for all nodes to be Ready
    local node_ready_check="[[ \$(oc get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type==\"Ready\" and .status==\"True\")) | .metadata.name' | wc -l | tr -d '\n') -eq ${total_nodes_count} ]]"
    
    if ! wait_for_condition "all nodes to be Ready" \
        "${node_ready_check}" \
        "${NODE_READY_TIMEOUT}" 60 \
        "Not all nodes are Ready after ${NODE_READY_TIMEOUT} minutes" \
        "oc get nodes -o wide | head -10"; then
        print_cluster_diagnostics "NODE READY FAILURE"
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Detailed node conditions:"
        run_command "oc get nodes -o json | jq '.items[] | {name: .metadata.name, conditions: .status.conditions[] | select(.type==\"Ready\")}'" || true
        return 1
    fi
    
    # Wait for cluster operators to stabilize
    local cluster_operator_check="[[ \$(oc get clusteroperators --no-headers 2>/dev/null | grep -v '${CLUSTER_OPERATOR_STABLE_PATTERN}' | wc -l | tr -d '\n') -eq 0 ]]"
    
    if ! wait_for_condition "cluster operators to stabilize" \
        "${cluster_operator_check}" \
        "${CLUSTER_OPERATOR_TIMEOUT}" 60 \
        "Some cluster operators are still not stable after ${CLUSTER_OPERATOR_TIMEOUT} minutes" \
        "oc get clusteroperators | head -10"; then
        print_cluster_diagnostics "CLUSTER OPERATOR FAILURE"
        echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Unstable cluster operators details:"
        run_command "oc get clusteroperators --no-headers | grep -v '${CLUSTER_OPERATOR_STABLE_PATTERN}' || true" || true
        return 1
    fi
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Cluster reboot test completed successfully"
    
    # Output final cluster status for verification
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - FINAL CLUSTER STATUS VERIFICATION"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Node Status:"
    run_command "oc get nodes -o wide" || true
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Cluster Operators Status:"
    run_command "oc get clusteroperators" || true
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - Machine Config Pools Status:"
    run_command "oc get machineconfigpools" || true
    
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - END FINAL STATUS VERIFICATION"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - =========================================="
    
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
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if ! reboot_cluster; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - ERROR: reboot_cluster function failed"
    exit 1
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - All reboot operations completed successfully"
