#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Function to get current timestamp
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Function to log with timestamp
log() {
    echo "$(get_timestamp) - $*"
}

# Enhanced error handling function
error_handler() {
    local exit_code=$?
    local line_number=$1
    local command="$2"
    
    log "==========================================" >&2
    log "ERROR: Script failed unexpectedly!" >&2
    log "==========================================" >&2
    log "Exit code: ${exit_code}" >&2
    log "Line number: ${line_number}" >&2
    log "Failed command: ${command}" >&2
    log "Current working directory: $(pwd)" >&2
    log "Current user: $(whoami)" >&2
    log "Process ID: $$" >&2
    log "Parent process ID: $PPID" >&2
    log "Shell options: $-" >&2
    log "==========================================" >&2
    log "Stack trace:" >&2
    local frame=0
    while caller $frame; do
        ((frame++))
    done >&2
    log "==========================================" >&2
    log "Environment variables:" >&2
    env | grep -E "(CLUSTER|AWS|KUBE|OPENSHIFT)" | sort >&2
    log "==========================================" >&2
    log "Recent command history:" >&2
    history | tail -10 >&2
    log "==========================================" >&2
    exit 1
}

# Add ERR trap to catch any unexpected exits
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

# Enhanced exit handler
exit_handler() {
    local exit_code=$?
    log "=========================================="
    log "Script execution completed"
    log "=========================================="
    log "Final exit code: ${exit_code}"
    log "Execution time: $((SECONDS)) seconds"
    log "Current time: $(get_timestamp)"
    log "=========================================="
}

# Add EXIT trap to log script completion
trap 'exit_handler' EXIT

# Reboot type configuration
# HARD_REBOOT: Use cloud provider commands (AWS EC2 stop/start, etc.)
# SOFT_REBOOT: Use SSH-based reboot (existing behavior)
readonly REBOOT_TYPE="${REBOOT_TYPE:-SOFT_REBOOT}"

# Record script start time for execution time calculation
SECONDS=0

log "=========================================="
log "Script execution started"
log "=========================================="
log "Script: $0"
log "Arguments: $*"
log "Process ID: $$"
log "Working directory: $(pwd)"
log "User: $(whoami)"
log "=========================================="

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
    bash -c "${CMD}" 2>/dev/null || echo ""
}

function wait_for_condition() {
    local condition_name="$1"
    local check_command="$2"
    local max_attempts="$3"
    local sleep_interval="$4"
    local failure_message="$5"
    local show_status_command="$6"  # Optional command to show status (both during waiting and on success)
    
    local attempt=0
    
    log "Waiting for ${condition_name}..."
    
    while [[ ${attempt} -lt ${max_attempts} ]]; do
        if eval "${check_command}"; then
            log "✅ ${condition_name} condition met"
            
            # Show success details if command provided
            if [[ -n "${show_status_command}" ]]; then
                log ""
                log "📊 ${condition_name} success details:"
                eval "${show_status_command}" || true
                log ""
            fi
            
            return 0
        fi
        
        log "⏳ ${condition_name} not ready, waiting... (${attempt}/${max_attempts})"
        
        # Show current status if command provided and at specific intervals
        if [[ -n "${show_status_command}" ]] && [[ ${attempt} -eq 0 ]] || [[ $((attempt % 5)) -eq 0 ]]; then
            log ""
            log "📋 Current ${condition_name} status:"
            eval "${show_status_command}" || true
            log ""
        fi
        
        sleep "${sleep_interval}"
        attempt=$(( attempt + 1 ))
    done
    
    log "❌ ERROR: ${failure_message}"
    return 1
}


function get_infra_id() {
    local infra_id=""
    if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
        infra_id=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
    fi
    echo "${infra_id}"
}

# Function to wait for cluster to be fully recovered after reboot
function wait_for_cluster_recovery() {
    log "=========================================="
    log "Waiting for cluster to fully recover after reboot"
    log "=========================================="
    
    # Wait for API server to be accessible (oc wait will fail immediately if API is not available)
    log "Waiting for API server to be accessible..."
    local api_attempt=0
    local max_api_attempts=120  # 120 attempts × 5 seconds = 10 minutes
    while [[ ${api_attempt} -lt ${max_api_attempts} ]]; do
        if oc cluster-info >/dev/null 2>&1; then
            log "✅ API server is accessible"
            break
        fi
        log "⏳ API server not accessible, waiting... (${api_attempt}/${max_api_attempts})"
        sleep 5
        api_attempt=$((api_attempt + 1))
    done
    
    if [[ ${api_attempt} -ge ${max_api_attempts} ]]; then
        log "ERROR: API server not accessible after 10 minutes"
        return 1
    fi
    
    # Wait for all nodes to be Ready
    log "Waiting for all nodes to be Ready..."
    if ! oc wait nodes --all --for=condition=Ready=true --timeout=60m; then
        log "ERROR: Not all nodes are Ready after reboot"
        return 1
    fi
    log "✅ All nodes are Ready"
    
    # Wait for all cluster operators to be Available
    log "Waiting for all cluster operators to be Available..."
    if ! oc wait clusteroperators --all --for='condition=Available=True' --timeout=60m; then
        log "ERROR: Not all cluster operators are Available after reboot"
        return 1
    fi
    log "✅ All cluster operators are Available"
    
    log "=========================================="
    log "Cluster recovery completed successfully"
    log "=========================================="
    return 0
}

# AWS hard reboot function - simplified logic with inline functions
function reboot_cluster_aws_hard() {
    local all_instances infra_id
    # Local timeout configuration - 60 attempts × 10 seconds = 10 minutes
    local aws_instance_timeout=60
    
    log "Using AWS hard reboot - simplified logic"
    
    # Get all instances for the cluster
    infra_id=$(get_infra_id)
    if [[ -z "${infra_id}" ]]; then
        log "ERROR: Could not get INFRA_ID from metadata.json"
        return 1
    fi
    
    local aws_output
    if ! aws_output=$(aws ec2 describe-instances --region "${AWS_REGION}" --filters "Name=tag-key,Values=kubernetes.io/cluster/${infra_id}" 'Name=instance-state-name,Values=running,stopped,pending,stopping' --query 'Reservations[*].Instances[*].InstanceId' --output text 2>&1); then
        log "ERROR: AWS command failed: ${aws_output}"
        return 1
    fi
    all_instances=$(echo "${aws_output}" | tr '\n' ' ' | sed 's/ $//')
    if [[ -z "${all_instances}" ]]; then
        log "ERROR: Could not find any instances for the cluster (infra_id: ${infra_id})"
        return 1
    fi
    
    log "Found instances: ${all_instances}"
    
    # Step 1: Stop all instances (inline batch_stop_all_aws_instances)
    log "Stopping all instances..."
    if ! run_command "aws ec2 stop-instances --region '${AWS_REGION}' --instance-ids ${all_instances}"; then
        log "ERROR: Failed to stop instances"
        return 1
    fi
    log "Successfully initiated stop for all instances"
    
    # Step 2: Check stopped instances count (inline wait_for_all_aws_instances_to_stop)
    log "Checking stopped instances count..."
    infra_id=$(get_infra_id)
    if [[ -z "${infra_id}" ]]; then
        log "ERROR: Could not get INFRA_ID from metadata.json"
        return 1
    fi
    
    if ! wait_for_condition "all instances to stop" \
        "[[ \$(aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' 'Name=instance-state-name,Values=running,stopped,pending,stopping' --query 'Reservations[*].Instances[*].State.Name' --output text | grep -v 'stopped' | wc -l) -eq 0 ]]" \
        "${aws_instance_timeout}" 10 \
        "Not all instances stopped within 10 minutes" \
        "aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' 'Name=instance-state-name,Values=running,stopped,pending,stopping' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text"; then
        log "ERROR: Not all instances stopped within timeout"
        return 1
    fi
    log "All instances have stopped successfully"
    
    # Step 3: Start all instances (inline batch_start_all_aws_instances)
    log "Starting all instances..."
    if ! run_command "aws ec2 start-instances --region '${AWS_REGION}' --instance-ids ${all_instances}"; then
        log "ERROR: Failed to start instances"
        return 1
    fi
    log "Successfully initiated start for all instances"
    
    # Step 4: Check running instances count (inline wait_for_all_aws_instances_to_start)
    log "Checking running instances count..."
    if ! wait_for_condition "all instances to start" \
        "[[ \$(aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' 'Name=instance-state-name,Values=running,stopped,pending,stopping' --query 'Reservations[*].Instances[*].State.Name' --output text | grep -v 'running' | wc -l) -eq 0 ]]" \
        "${aws_instance_timeout}" 10 \
        "Not all instances started within 10 minutes" \
        "aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' 'Name=instance-state-name,Values=running,stopped,pending,stopping' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text"; then
        log "ERROR: Not all instances started within timeout"
        return 1
    fi
    log "All instances have started successfully"
    
    log "AWS hard reboot completed successfully"
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
    local node_ip=$1 ret=0

    ssh_command "${node_ip}" "sudo reboot" || ret=1
    if [[ ${ret} == 1 ]]; then
        log "ERROR: fail to reboot vm instance ${node_ip}"
        return 1
    fi
}

function reboot_cluster_soft() {
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
        log "rebooting node ${node_name}, node ip is ${node_ip}"
        reboot_node "${node_ip}"
    done

    total_nodes_count=$(echo "${node_list}" | awk '{print NF}')
    try=0
    max_try=30
    while [[ ${try} -lt ${max_try} ]]; do
	if [[ $(oc get node --no-headers | grep -c 'Ready') -eq ${total_nodes_count} ]]; then
            log "cluster boot up, get ready"
            break
        fi
        log "wait for node boot up"
        sleep 60
        try=$(( try + 1 ))
    done

    if [ "${try}" == "${max_try}" ]; then
	log "ERROR: some nodes are not ready!"
        run_command "oc get node"
        return 1
    else
        return 0
    fi
}

if [[ "${ENABLE_REBOOT_CHECK}" != "true" ]]; then
    log "ENV 'ENABLE_REBOOT_CHECK' is not set to 'true', skip the operation of rebooting nodes..."
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

if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    log "ERROR: ${SHARED_DIR}/kubeconfig not found, no cluster is available"
    exit 1
fi
export KUBECONFIG=${SHARED_DIR}/kubeconfig

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ "${REBOOT_TYPE}" == "HARD_REBOOT" ]; then
    case "${CLUSTER_TYPE}" in
        aws)
            export AWS_REGION="${LEASED_RESOURCE}"
            export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
            if ! reboot_cluster_aws_hard; then
                log "ERROR: reboot_cluster_aws_hard function failed"
                exit 1
            fi
            ;;
        *)
            log "ERROR: HARD_REBOOT is not supported in platform ${CLUSTER_TYPE}. This is a configuration error, please fix it."
            exit 1
            ;;
    esac
elif [ "${REBOOT_TYPE}" == "SOFT_REBOOT" ]; then
    if ! reboot_cluster_soft; then
        log "ERROR: reboot_cluster_soft function failed"
        exit 1
    fi
else
    log "REBOOT_TYPE $REBOOT_TYPE is not supported, exit now."
    exit 1
fi

log "All reboot operations completed successfully"

# Wait for cluster to fully recover after reboot (applies to both HARD_REBOOT and SOFT_REBOOT)
if ! wait_for_cluster_recovery; then
    log "ERROR: Cluster recovery failed after reboot"
    exit 1
fi
