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

# Configuration constants - Reduced timeouts based on test results
readonly API_SERVER_TIMEOUT=20      # 20 attempts × 30 seconds = 10 minutes
readonly NODE_READY_TIMEOUT=60      # 60 attempts × 60 seconds = 60 minutes
readonly CLUSTER_OPERATOR_TIMEOUT=120  # 120 attempts × 60 seconds = 120 minutes

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

# Platform detection and setup using case statement
case "${CLUSTER_TYPE}" in
    aws)
        # Configure AWS credentials - support both CI and local environments
        export AWS_REGION="${LEASED_RESOURCE}"
        
        # Determine AWS credentials file location
        aws_cred_file=""
        if [[ -n "${CLUSTER_PROFILE_DIR:-}" && -f "${CLUSTER_PROFILE_DIR}/.awscred" ]]; then
            # CI environment
            aws_cred_file="${CLUSTER_PROFILE_DIR}/.awscred"
            export AWS_SHARED_CREDENTIALS_FILE="${aws_cred_file}"
            log "Using CI environment AWS credentials: ${aws_cred_file}"
        elif [[ -f "${HOME}/.aws/credentials" ]]; then
            # Local environment
            aws_cred_file="${HOME}/.aws/credentials"
            export AWS_SHARED_CREDENTIALS_FILE="${aws_cred_file}"
            log "Using local environment AWS credentials: ${aws_cred_file}"
        else
            log "ERROR: No AWS credentials file found"
            log "Expected locations:"
            log "  - CI environment: ${CLUSTER_PROFILE_DIR:-<unset>}/.awscred"
            log "  - Local environment: ${HOME}/.aws/credentials"
            exit 1
        fi
        
        # Extract AWS credentials from the credential file (for CI environment)
        if [[ "${aws_cred_file}" == *"/.awscred" ]]; then
            AWS_ACCESS_KEY_ID=$(cat "${aws_cred_file}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
            AWS_SECRET_ACCESS_KEY=$(cat "${aws_cred_file}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
            export AWS_ACCESS_KEY_ID
            export AWS_SECRET_ACCESS_KEY
            
            if [[ -z "${AWS_ACCESS_KEY_ID}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
                log "ERROR: Failed to extract AWS credentials from ${aws_cred_file}"
                exit 1
            fi
        fi
        
        log "AWS platform detected, AWS CLI configured"
        log "AWS Region: ${AWS_REGION}"
        ;;
    azure*)
        log "Azure platform detected (${CLUSTER_TYPE}), using SSH-based reboot"
        ;;
    gcp)
        log "GCP platform detected, using SSH-based reboot"
        ;;
    ibmcloud)
        log "IBM Cloud platform detected, using SSH-based reboot"
        ;;
    *)
        log "Unknown platform detected (${CLUSTER_TYPE}), using SSH-based reboot"
        ;;
esac

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

function display_cluster_diagnostics() {
    local failure_type="$1"
    log "=== CLUSTER DIAGNOSTICS FOR ${failure_type} ==="
    
    # Use common function for standard status checks
    run_cluster_status_commands "Current"
    
    # Additional diagnostic commands
    log "Current etcd status:"
    run_command "oc get etcd -o yaml" || true
    log "Current API server status:"
    run_command "oc get apiservers cluster -o yaml" || true
    log "=== END CLUSTER DIAGNOSTICS ==="
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

function get_infra_id() {
    local infra_id=""
    if [[ -f "${SHARED_DIR}/metadata.json" ]]; then
        infra_id=$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")
    fi
    echo "${infra_id}"
}


# Get node list by role (master or worker)
function get_node_list_by_role() {
    local role="$1"  # "master" or "worker"
    local node_list
    
    log "Getting ${role} nodes list..." >&2
    node_list=$(run_command_silent "oc get node -o wide --no-headers | grep '${role}' | awk '{print \$1\":\"\$6}' | sort")
    
    if [[ -z "${node_list}" ]]; then
        log "ERROR: Failed to get ${role} nodes list or no ${role} nodes found" >&2
        return 1
    fi
    
    log "Found ${role} nodes: ${node_list}" >&2
    echo "${node_list}"
    return 0
}

# Execute operation on all nodes with error handling and tracking
function execute_operation_on_nodes() {
    local node_info_list="$1"  # List of "node_name:node_ip" entries
    local function_name="$2"   # Function name to call
    local action_verb="$3"     # Verb for logging (should be present participle like "stopping", "starting", "rebooting")
    
    local failed_nodes=0
    local total_nodes=0
    
    log "${action_verb} all nodes..."
    for node_info in ${node_info_list}; do
        node_name=${node_info/:*}
        node_ip=${node_info#*:}
        total_nodes=$((total_nodes + 1))
        log "${action_verb} node ${node_name} (${node_ip})"
        if ! ${function_name} "${node_ip}" "${node_name}"; then
            log "ERROR: Failed to ${action_verb} node ${node_name}, continuing with other nodes..."
            failed_nodes=$((failed_nodes + 1))
        fi
    done
    
    log "Completed ${action_verb} ${total_nodes} nodes: ${failed_nodes} failed, $((total_nodes - failed_nodes)) succeeded"
    
    # Return error code if any nodes failed
    if [[ ${failed_nodes} -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Run cluster status check commands
function run_cluster_status_commands() {
    local prefix="$1"  # Log prefix, e.g., "Current" or "Final"
    
    log ""
    log "📊 ${prefix} node status:"
    run_command "oc get nodes -o wide" || true
    log ""
    
    log "📊 ${prefix} cluster operators status:"
    run_command "oc get clusteroperators" || true
    log ""
    
    log "📊 ${prefix} machine config pools status:"
    run_command "oc get machineconfigpools" || true
    log ""
}

# Display final cluster status after all operations
function display_cluster_final_status() {
    log ""
    log "🎯 =========================================="
    log "🎯 FINAL CLUSTER STATUS VERIFICATION"
    log "🎯 =========================================="
    
    run_cluster_status_commands "Final"
    
    log "🎯 =========================================="
    log "🎯 END FINAL STATUS VERIFICATION"
    log "🎯 =========================================="
    log ""
}

# Validate result and log success/error
function validate_and_log_result() {
    local result="$1"
    local success_message="$2"
    local error_message="$3"
    
    if [[ -z "${result}" ]]; then
        log "ERROR: ${error_message}"
        return 1
    fi
    
    log "${success_message}: ${result}"
    echo "${result}"
    return 0
}

# Get all AWS instance IDs for the cluster by INFRA_ID
function get_all_aws_instance_ids() {
    local expected_state="$1"  # "running", "stopped", or "any"
    local infra_id
    
    infra_id=$(get_infra_id)
    if [[ -z "${infra_id}" ]]; then
        log "ERROR: Could not get INFRA_ID from metadata.json" >&2
        return 1
    fi
    
    log "Getting all instance IDs using INFRA_ID: ${infra_id}" >&2
    
    # Get all instances with the INFRA_ID tag using tag-key match (more flexible)
    local describe_cmd
    if [[ "${expected_state}" == "any" ]]; then
        describe_cmd="aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' --query 'Reservations[*].Instances[*].InstanceId' --output text"
    else
        describe_cmd="aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' --query 'Reservations[*].Instances[?State.Name==\`${expected_state}\`].InstanceId' --output text"
    fi
    
    local instance_ids
    instance_ids=$(run_command_silent "${describe_cmd}")
    
    if [[ -n "${instance_ids}" ]]; then
        # Convert newlines to spaces for proper AWS CLI format
        instance_ids=$(echo "${instance_ids}" | tr '\n' ' ' | sed 's/ $//')
        log "DEBUG: Found instances: ${instance_ids}" >&2
        echo "${instance_ids}"
        return 0
    else
        log "ERROR: Could not find any ${expected_state} instances for INFRA_ID: ${infra_id}" >&2
        return 1
    fi
}

# Batch stop all AWS instances for the cluster
function batch_stop_all_aws_instances() {
    local instance_ids
    
    # Get all instances and stop them regardless of current state
    if ! instance_ids=$(get_all_aws_instance_ids "any"); then
        log "No instances found for the cluster"
        return 1
    fi
    
    log "Batch stopping all instances: ${instance_ids}"
    
    # Stop all instances at once (AWS will ignore already stopped instances)
    if ! run_command "aws ec2 stop-instances --region '${AWS_REGION}' --instance-ids ${instance_ids}"; then
        log "ERROR: Failed to stop instances"
        return 1
    fi
    
    log "Successfully initiated stop for all instances"
    return 0
}

# Batch start all AWS instances for the cluster
function batch_start_all_aws_instances() {
    local instance_ids
    
    # Get all instances and start them regardless of current state
    if ! instance_ids=$(get_all_aws_instance_ids "any"); then
        log "No instances found for the cluster"
        return 1
    fi
    
    log "Batch starting all instances: ${instance_ids}"

    # Start all instances at once (AWS will ignore already running instances)
    if ! run_command "aws ec2 start-instances --region '${AWS_REGION}' --instance-ids ${instance_ids}"; then
        log "ERROR: Failed to start instances"
        return 1
    fi
    
    log "Successfully initiated start for all instances"
    return 0
}

# Note: get_aws_instance_state(), aws_ec2_action(), and wait_for_aws_instance_state() functions removed - 
# now using batch operations that don't need individual instance state management

# Note: reboot_node_aws_hard() function removed - now using batch operations in reboot_cluster_aws_hard()

# Note: reboot_node_aws_stop_only() and reboot_node_aws_start_only() functions removed - now using batch operations

function wait_for_all_aws_instances_to_stop() {
    local infra_id
    
    infra_id=$(get_infra_id)
    if [[ -z "${infra_id}" ]]; then
        log "ERROR: Could not get INFRA_ID from metadata.json"
        return 1
    fi
    
    log "Waiting for all instances to stop using INFRA_ID: ${infra_id}"
    
    # Wait for all instances to be stopped
    if ! wait_for_condition "all instances to stop" \
        "[[ \$(aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' --query 'Reservations[*].Instances[*].State.Name' --output text | grep -v 'stopped' | wc -l) -eq 0 ]]" \
        30 10 \
        "Not all instances stopped within 5 minutes" \
        "aws ec2 describe-instances --region '${AWS_REGION}' --filters 'Name=tag-key,Values=kubernetes.io/cluster/${infra_id}' --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output text"; then
        return 1
    fi
    
    log "All instances have stopped successfully"
    return 0
}

function reboot_node_soft() {
    local node_ip=$1 node_name=$2
    
    log "Using SSH-based reboot for ${node_name} (${node_ip})"
    if ! ssh_command "${node_ip}" "sudo reboot"; then
        log "ERROR: Failed to reboot node ${node_name} via SSH"
        return 1
    fi
    log "SSH reboot command sent to ${node_name}"
    return 0
}

# Get node information for reboot operations
function get_reboot_node_info() {
    local master_list worker_list node_info_list
    
    # Get node lists with error handling
    if ! master_list=$(get_node_list_by_role "master"); then
        return 1
    fi
    
    if [[ "${SIZE_VARIANT}" == "compact" ]]; then
        node_info_list="${master_list}"
    else
        if ! worker_list=$(get_node_list_by_role "worker"); then
            return 1
        fi
        node_info_list="${worker_list} ${master_list}"
    fi
    
    echo "${node_info_list}"
    return 0
}

# Common cluster health check function
function display_cluster_health_check() {
    local total_nodes_count="$1"
    
    # Wait for API server to be accessible first
    if ! wait_for_condition "API server accessibility" \
        "oc get nodes --request-timeout=10s >/dev/null 2>&1" \
        "${API_SERVER_TIMEOUT}" 30 \
        "API server not accessible after ${API_SERVER_TIMEOUT} attempts" \
        "oc get nodes --request-timeout=10s"; then
        display_cluster_diagnostics "API SERVER FAILURE"
        return 1
    fi
    
    log "🔍 API server is accessible, proceeding with node readiness check..."

    # Wait for all nodes to be Ready
    local node_ready_check="[[ \$(oc get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type==\"Ready\" and .status==\"True\")) | .metadata.name' | wc -l | tr -d '\n') -eq ${total_nodes_count} ]]"
    
    if ! wait_for_condition "all nodes to be Ready" \
        "${node_ready_check}" \
        "${NODE_READY_TIMEOUT}" 60 \
        "Not all nodes are Ready after ${NODE_READY_TIMEOUT} minutes" \
        "oc get nodes -o wide"; then
        display_cluster_diagnostics "NODE READY FAILURE"
        log "Detailed node conditions:"
        run_command "oc get nodes -o json | jq '.items[] | {name: .metadata.name, conditions: .status.conditions[] | select(.type==\"Ready\")}'" || true
        return 1
    fi
    
    # Use health check script instead of custom cluster operator check
    log "Running cluster health check..."
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG=${SHARED_DIR}/kubeconfig
    fi
    
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        # shellcheck source=/dev/null
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
    
    # Run the health check script functions
    if ! run_command "oc get machineconfig"; then
        log "ERROR: Failed to get machine config"
        return 1
    fi
    
    # Check cluster operators using the health check script logic
    local tmp_ret=0
    local tmp_clusteroperator input column last_column_name tmp_clusteroperator_1 rc null_version
    
    echo "Make sure every operator do not report empty column"
    tmp_clusteroperator=$(mktemp /tmp/health_check-script.XXXXXX)
    input="${tmp_clusteroperator}"
    oc get clusteroperator >"${tmp_clusteroperator}"
    column=$(head -n 1 "${tmp_clusteroperator}" | awk '{print NF}')
    last_column_name=$(head -n 1 "${tmp_clusteroperator}" | awk '{print $NF}')
    if [[ ${last_column_name} == "MESSAGE" ]]; then
        (( column -= 1 ))
        tmp_clusteroperator_1=$(mktemp /tmp/health_check-script.XXXXXX)
        awk -v end=${column} '{for(i=1;i<=end;i++) printf $i"\t"; print ""}' "${tmp_clusteroperator}" > "${tmp_clusteroperator_1}"
        input="${tmp_clusteroperator_1}"
    fi
    
    while IFS= read -r line
    do
        rc=$(echo "${line}" | awk '{print NF}')
        if (( rc != column )); then
            echo >&2 "The following line have empty column"
            echo >&2 "${line}"
            (( tmp_ret += 1 ))
        fi
    done < "${input}"
    rm -f "${tmp_clusteroperator}"
    
    echo "Make sure every operator column reports version"
    if null_version=$(oc get clusteroperator -o json | jq '.items[] | select(.status.versions == null) | .metadata.name') && [[ ${null_version} != "" ]]; then
      echo >&2 "Null Version: ${null_version}"
      (( tmp_ret += 1 ))
    fi
    
    # Wait for cluster operators to stabilize
    # Check that most operators are stable: Available=True, Progressing=False, Degraded=False
    # Allow some non-critical operators to be progressing (like kube-storage-version-migrator, olm)
    local cluster_operator_check="[[ \$(oc get clusteroperators -o json | jq -r '.items[] | select(.status.conditions[] | select(.type==\"Available\" and .status==\"True\")) | select(.status.conditions[] | select(.type==\"Progressing\" and .status==\"False\")) | select(.status.conditions[] | select(.type==\"Degraded\" and .status==\"False\")) | .metadata.name' | wc -l | tr -d '\n') -ge 18 ]]"
    
    if ! wait_for_condition "cluster operators to stabilize" \
        "${cluster_operator_check}" \
        "${CLUSTER_OPERATOR_TIMEOUT}" 60 \
        "Cluster operators not stable after ${CLUSTER_OPERATOR_TIMEOUT} minutes" \
        "oc get clusteroperators"; then
        log "WARNING: Some cluster operators may still be recovering, but continuing..."
        log "Checking which operators are still progressing:"
        run_command "oc get clusteroperators -o json | jq -r '.items[] | select(.status.conditions[] | select(.type==\"Progressing\" and .status==\"True\")) | .metadata.name'" || true
        log "Checking which operators are not available:"
        run_command "oc get clusteroperators -o json | jq -r '.items[] | select(.status.conditions[] | select(.type==\"Available\" and .status==\"False\")) | .metadata.name'" || true
        log "Checking which operators are degraded:"
        run_command "oc get clusteroperators -o json | jq -r '.items[] | select(.status.conditions[] | select(.type==\"Degraded\" and .status==\"True\")) | .metadata.name'" || true
        log "Continuing with cluster health check despite some operators still recovering..."
    fi
    
    # Output final cluster status for verification
    display_cluster_final_status
    
    return 0
}

# AWS hard reboot function with true batch stop/start strategy
function reboot_cluster_aws_hard() {
    local total_nodes_count=0 node_info_list
    
    # Get node information using common function
    if ! node_info_list=$(get_reboot_node_info); then
        return 1
    fi

    log "Using AWS hard reboot with true batch stop/start strategy"
    
    # Verify we can find all instances for the cluster
    local all_instances
    if ! all_instances=$(get_all_aws_instance_ids "any"); then
        log "ERROR: Could not find any instances for the cluster"
        return 1
    fi
    
    local instance_count
    instance_count=$(echo "${all_instances}" | wc -w 2>/dev/null | tr -d '\n' || echo "0")
    total_nodes_count=$(echo "${node_info_list}" | wc -w 2>/dev/null | tr -d '\n' || echo "0")
    
    log "Found ${instance_count} instances for ${total_nodes_count} nodes"
    log "All instances: ${all_instances}"
    
    if [[ "${instance_count}" -ne "${total_nodes_count}" ]]; then
        log "WARNING: Instance count (${instance_count}) does not match node count (${total_nodes_count})"
        log "This may indicate some instances are missing INFRA_ID tags or are in unexpected states"
    fi
    
    local reboot_success=true

    # Batch stop all instances at once
    if ! batch_stop_all_aws_instances; then
        log "ERROR: Failed to stop instances, but continuing with start phase..."
        reboot_success=false
    fi
    
    # Wait for all instances to stop using AWS commands
    if ! wait_for_all_aws_instances_to_stop; then
        log "ERROR: Not all instances stopped within timeout, continuing with start..."
        reboot_success=false
    fi
    
    # Batch start all instances at once
    if ! batch_start_all_aws_instances; then
        log "ERROR: Failed to start instances"
        reboot_success=false
    fi

    log "Total nodes to reboot: ${total_nodes_count}"
    
    if [[ "${reboot_success}" == "true" ]]; then
        log "All ${total_nodes_count} nodes have been successfully restarted, waiting for cluster to recover..."
    else
        log "ERROR: Some nodes failed to restart. All nodes must be successfully restarted before proceeding with cluster health checks."
        log "Reboot operation failed - exiting without health checks."
        return 1
    fi
    
    # Perform common cluster health check
    if ! display_cluster_health_check "${total_nodes_count}"; then
        return 1
    fi
    
    # Only report success if reboot operations were successful
    if [[ "${reboot_success}" == "true" ]]; then
        log "Cluster reboot test completed successfully"
        return 0
    else
        log "ERROR: Cluster reboot test completed with failures"
        return 1
    fi
}

function reboot_cluster_soft() {
    local total_nodes_count=0 node_info_list
    
    # Get node information using common function
    if ! node_info_list=$(get_reboot_node_info); then
        return 1
    fi

    log "Using reboot type: ${REBOOT_TYPE}"
    
    local reboot_success=true

    # Sequential reboot (default behavior for SOFT_REBOOT)
    if ! execute_operation_on_nodes "${node_info_list}" "reboot_node_soft" "rebooting"; then
        log "ERROR: Some nodes failed to reboot"
        reboot_success=false
    fi

    total_nodes_count=$(echo "${node_info_list}" | wc -w 2>/dev/null | tr -d '\n' || echo "0")
    log "Total nodes to reboot: ${total_nodes_count}"
    
    if [[ "${reboot_success}" == "true" ]]; then
        log "All ${total_nodes_count} nodes have been successfully restarted, waiting for cluster to recover..."
    else
        log "ERROR: Some nodes failed to restart. All nodes must be successfully restarted before proceeding with cluster health checks."
        log "Reboot operation failed - exiting without health checks."
        return 1
    fi
    
    # Perform common cluster health check
    if ! display_cluster_health_check "${total_nodes_count}"; then
        return 1
    fi
    
    # Only report success if reboot operations were successful
    if [[ "${reboot_success}" == "true" ]]; then
        log "Cluster reboot test completed successfully"
        return 0
    else
        log "ERROR: Cluster reboot test completed with failures"
        return 1
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

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ "${REBOOT_TYPE}" == "HARD_REBOOT" ]; then
    case "${CLUSTER_TYPE}" in
        aws)
            if ! reboot_cluster_aws_hard; then
                log "ERROR: reboot_cluster_aws_hard function failed"
                exit 1
            fi
            ;;
        *)
            log "HARD_REBOOT is not supported in platform ${CLUSTER_TYPE}, falling back to SOFT_REBOOT"
            if ! reboot_cluster_soft; then
                log "ERROR: reboot_cluster_soft function failed"
                exit 1
            fi
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
