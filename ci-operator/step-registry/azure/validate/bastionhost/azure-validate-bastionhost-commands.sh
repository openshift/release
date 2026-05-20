#!/bin/bash

set -o nounset
set -o pipefail
set -x  # Enable debug logging

# Ensure our UID is in /etc/passwd for SSH
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

VALIDATION_LOG="${ARTIFACT_DIR}/bastion-validation.log"
VALIDATION_RESULTS="${ARTIFACT_DIR}/bastion-validation-results.txt"

# Initialize results
echo "=== Azure Bastion Host Validation ===" | tee "${VALIDATION_LOG}"
echo "Started: $(date -u --rfc-3339=seconds)" | tee -a "${VALIDATION_LOG}"
echo "" | tee -a "${VALIDATION_LOG}"

VALIDATION_PASSED=true

#####################################
###########Helper Functions##########
#####################################
function log() {
    echo "[$(date -u --rfc-3339=seconds)] $*" | tee -a "${VALIDATION_LOG}"
}

function run_ssh_cmd() {
    local sshkey=$1
    local user=$2
    local host=$3
    local remote_cmd=$4
    local description=$5

    log "Running: ${description}"
    options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=10"

    # Disable tracing for SSH commands to avoid leaking sensitive data
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    output=$(ssh ${options} -i "${sshkey}" ${user}@${host} "${remote_cmd}" 2>&1)
    ret=$?

    $WAS_TRACING && set -x

    echo "${output}" | tee -a "${VALIDATION_LOG}"
    return ${ret}
}

#####################################
##########Read Bastion Info##########
#####################################
if [[ ! -f "${SHARED_DIR}/bastion_public_address" ]]; then
    log "ERROR: bastion_public_address not found in ${SHARED_DIR}"
    echo "FAILED: Bastion not provisioned" > "${VALIDATION_RESULTS}"
    exit 1
fi

BASTION_PUBLIC_IP=$(cat "${SHARED_DIR}/bastion_public_address")
BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")
SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

log "Bastion Public IP: ${BASTION_PUBLIC_IP}"
log "Bastion SSH User: ${BASTION_SSH_USER}"
log ""

#####################################
###Check 1: SSH Access to Bastion###
#####################################
log "CHECK 1: Verifying SSH access to bastion host..."

# Wait for SSH to become available (bastion may have just been provisioned)
SSH_READY=false
MAX_RETRIES=30
RETRY_DELAY=10

for ((i=1; i<=MAX_RETRIES; i++)); do
    if run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" "echo 'SSH connection successful'" "SSH connectivity test (attempt $i/$MAX_RETRIES)"; then
        SSH_READY=true
        break
    fi

    if [[ $i -lt $MAX_RETRIES ]]; then
        log "Waiting ${RETRY_DELAY}s before retry..."
        sleep ${RETRY_DELAY}
    fi
done

if ${SSH_READY}; then
    log "✓ PASSED: SSH access to bastion is working"
    echo "SSH_ACCESS=PASS" >> "${VALIDATION_RESULTS}"
else
    log "✗ FAILED: Cannot SSH to bastion host after ${MAX_RETRIES} attempts"
    echo "SSH_ACCESS=FAIL" >> "${VALIDATION_RESULTS}"
    VALIDATION_PASSED=false
fi
log ""

#####################################
##Check 2: Container Runtime Present#
#####################################
log "CHECK 2: Checking for container runtime (podman/docker)..."

# Check for podman
if run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" "which podman && podman --version" "Check for podman"; then
    log "✓ PASSED: Podman is installed"
    CONTAINER_RUNTIME="podman"
    echo "CONTAINER_RUNTIME=podman" >> "${VALIDATION_RESULTS}"
# Check for docker
elif run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" "which docker && docker --version" "Check for docker"; then
    log "✓ PASSED: Docker is installed"
    CONTAINER_RUNTIME="docker"
    echo "CONTAINER_RUNTIME=docker" >> "${VALIDATION_RESULTS}"
else
    log "✗ FAILED: Neither podman nor docker found on bastion"
    echo "CONTAINER_RUNTIME=NONE" >> "${VALIDATION_RESULTS}"
    VALIDATION_PASSED=false
    CONTAINER_RUNTIME=""
fi
log ""

#####################################
#Check 3: Container Runtime Working##
#####################################
if [[ -n "${CONTAINER_RUNTIME}" ]]; then
    log "CHECK 3: Testing container runtime functionality..."

    test_cmd="${CONTAINER_RUNTIME} run --rm quay.io/fedora/fedora-minimal:latest echo 'Container runtime test successful'"

    if run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" "${test_cmd}" "Run test container"; then
        log "✓ PASSED: Container runtime is functional"
        echo "CONTAINER_RUNTIME_FUNCTIONAL=PASS" >> "${VALIDATION_RESULTS}"
    else
        log "✗ FAILED: Container runtime exists but cannot run containers"
        echo "CONTAINER_RUNTIME_FUNCTIONAL=FAIL" >> "${VALIDATION_RESULTS}"
        VALIDATION_PASSED=false
    fi
    log ""
else
    log "SKIPPED: Container runtime functionality test (no runtime found)"
    echo "CONTAINER_RUNTIME_FUNCTIONAL=SKIPPED" >> "${VALIDATION_RESULTS}"
    log ""
fi

#####################################
##Check 4: Network Access to Cluster#
#####################################
log "CHECK 4: Verifying network connectivity from bastion to cluster..."

# Get cluster node IPs using oc/kubectl
KUBECONFIG="${SHARED_DIR}/kubeconfig"
NODE_IPS=""

if [[ -f "${KUBECONFIG}" ]]; then
    export KUBECONFIG
    # Try oc first, fall back to kubectl
    if command -v oc &>/dev/null; then
        NODE_IPS=$(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
    elif command -v kubectl &>/dev/null; then
        NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
    fi
fi

if [[ -n "${NODE_IPS}" ]]; then
    log "Found cluster nodes with IPs: ${NODE_IPS}"
    log "Testing network connectivity by pinging cluster nodes from bastion..."

    # Convert space-separated IPs to array
    read -ra NODE_IP_ARRAY <<< "${NODE_IPS}"

    # Ping each node (try first 3 nodes to save time)
    PING_SUCCESS=false
    NODES_TO_TEST=3
    for node_ip in "${NODE_IP_ARRAY[@]:0:${NODES_TO_TEST}}"; do
        log "Pinging node at ${node_ip}..."

        # Ping with 3 packets, 5 second timeout
        ping_cmd="ping -c 3 -W 5 ${node_ip}"

        if run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" "${ping_cmd}" "Ping node ${node_ip}"; then
            log "✓ Successfully pinged node ${node_ip}"
            PING_SUCCESS=true
            break
        else
            log "! Failed to ping node ${node_ip}"
        fi
    done

    if ${PING_SUCCESS}; then
        log "✓ PASSED: Network connectivity from bastion to cluster nodes is working"
        echo "CLUSTER_NETWORK_ACCESS=PASS" >> "${VALIDATION_RESULTS}"
    else
        log "✗ FAILED: Could not ping any cluster nodes from bastion"
        echo "CLUSTER_NETWORK_ACCESS=FAIL" >> "${VALIDATION_RESULTS}"
        VALIDATION_PASSED=false
    fi
else
    log "! SKIPPED: Could not retrieve cluster node IPs (cluster may not be ready or kubeconfig not available)"
    echo "CLUSTER_NETWORK_ACCESS=SKIPPED" >> "${VALIDATION_RESULTS}"
fi
log ""

#####################################
######Additional System Info#########
#####################################
log "Collecting additional bastion system information..."

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" \
    "uname -a" "System kernel info"

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" \
    "cat /etc/os-release" "OS version info"

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" \
    "df -h" "Disk space"

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" \
    "free -h" "Memory info"

run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" \
    "ip addr show" "Network interfaces"

# Azure-specific: check if Azure metadata service is accessible
run_ssh_cmd "${SSH_PRIV_KEY_PATH}" "${BASTION_SSH_USER}" "${BASTION_PUBLIC_IP}" \
    "curl -H Metadata:true 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' 2>&1 | head -20" \
    "Azure metadata service check"

log ""

#####################################
############Final Summary############
#####################################
log "=== Validation Summary ==="
cat "${VALIDATION_RESULTS}" | tee -a "${VALIDATION_LOG}"
log ""

if ${VALIDATION_PASSED}; then
    log "✓ ALL VALIDATIONS PASSED"
    echo "OVERALL=PASS" >> "${VALIDATION_RESULTS}"
    log "Completed: $(date -u --rfc-3339=seconds)"
    exit 0
else
    log "✗ SOME VALIDATIONS FAILED - Review ${VALIDATION_RESULTS} for details"
    echo "OVERALL=FAIL" >> "${VALIDATION_RESULTS}"
    log "Completed: $(date -u --rfc-3339=seconds)"
    exit 1
fi
