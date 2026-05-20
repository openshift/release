#!/bin/bash

set -o nounset
set -o pipefail
set -x  # Enable debug logging

# Cleanup function for temporary SSH keys
cleanup() {
    rm -f /tmp/ssh-privatekey /tmp/ssh-privatekey-pem1 /tmp/ssh-privatekey-pem2 /tmp/ssh-privatekey-pem3 2>/dev/null || true
}
trap cleanup EXIT

# Ensure our UID is in /etc/passwd for SSH
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
fi

VALIDATION_LOG="${ARTIFACT_DIR}/bastion-validation.log"
VALIDATION_RESULTS="${ARTIFACT_DIR}/bastion-validation-results.txt"

# Initialize results
echo "=== GCP Bastion Host Validation ===" | tee "${VALIDATION_LOG}"
echo "Started: $(date -u --rfc-3339=seconds)" | tee -a "${VALIDATION_LOG}"
echo "" | tee -a "${VALIDATION_LOG}"

# Log container environment details
echo "=== Container Environment ===" | tee -a "${VALIDATION_LOG}"
echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')" | tee -a "${VALIDATION_LOG}"
echo "User: $(whoami 2>/dev/null || echo 'unknown') (UID=$(id -u 2>/dev/null || echo 'unknown'))" | tee -a "${VALIDATION_LOG}"
echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'unknown')" | tee -a "${VALIDATION_LOG}"
echo "Kernel: $(uname -r 2>/dev/null || echo 'unknown')" | tee -a "${VALIDATION_LOG}"
echo "" | tee -a "${VALIDATION_LOG}"

# Check critical tool availability and versions
echo "=== Tool Availability ===" | tee -a "${VALIDATION_LOG}"

# Check ssh-keygen
if command -v ssh-keygen &>/dev/null; then
    SSH_KEYGEN_PROBE=$({ ssh-keygen -? 2>&1 || true; } | head -n1)
    echo "ssh-keygen: AVAILABLE" | tee -a "${VALIDATION_LOG}"
    echo "  Probe: ${SSH_KEYGEN_PROBE}" | tee -a "${VALIDATION_LOG}"
    echo "  Path: $(which ssh-keygen)" | tee -a "${VALIDATION_LOG}"
else
    echo "ssh-keygen: NOT FOUND" | tee -a "${VALIDATION_LOG}"
fi

# Check openssl
if command -v openssl &>/dev/null; then
    OPENSSL_VERSION=$(openssl version 2>&1)
    echo "openssl: AVAILABLE" | tee -a "${VALIDATION_LOG}"
    echo "  Version: ${OPENSSL_VERSION}" | tee -a "${VALIDATION_LOG}"
    echo "  Path: $(which openssl)" | tee -a "${VALIDATION_LOG}"
else
    echo "openssl: NOT FOUND" | tee -a "${VALIDATION_LOG}"
fi

# Check SSH version and upgrade if too old (OpenSSH < 7.8 doesn't support new key format)
SSH_VERSION=$(ssh -V 2>&1 | head -n1)
echo "ssh: AVAILABLE" | tee -a "${VALIDATION_LOG}"
echo "  Version: ${SSH_VERSION}" | tee -a "${VALIDATION_LOG}"
echo "  Path: $(which ssh)" | tee -a "${VALIDATION_LOG}"
echo "" | tee -a "${VALIDATION_LOG}"

if ssh -V 2>&1 | grep -qE "OpenSSH_([0-6]\.|7\.[0-7])"; then
    echo "SSH client is too old, attempting to upgrade to support OpenSSH key format..." | tee -a "${VALIDATION_LOG}"

    # Try different package managers
    if command -v dnf &>/dev/null; then
        echo "Using dnf to upgrade openssh-clients..." | tee -a "${VALIDATION_LOG}"
        dnf upgrade -y openssh-clients 2>&1 | tee -a "${VALIDATION_LOG}" || echo "dnf upgrade failed, continuing with existing SSH" | tee -a "${VALIDATION_LOG}"
    elif command -v yum &>/dev/null; then
        echo "Using yum to upgrade openssh-clients..." | tee -a "${VALIDATION_LOG}"
        yum upgrade -y openssh-clients 2>&1 | tee -a "${VALIDATION_LOG}" || echo "yum upgrade failed, continuing with existing SSH" | tee -a "${VALIDATION_LOG}"
    elif command -v apt-get &>/dev/null; then
        echo "Using apt-get to upgrade openssh-client..." | tee -a "${VALIDATION_LOG}"
        apt-get update &>/dev/null && apt-get install -y --only-upgrade openssh-client 2>&1 | tee -a "${VALIDATION_LOG}" || echo "apt-get upgrade failed, continuing with existing SSH" | tee -a "${VALIDATION_LOG}"
    else
        echo "No package manager found, continuing with existing SSH client" | tee -a "${VALIDATION_LOG}"
    fi

    # Check version after upgrade
    SSH_VERSION_AFTER=$(ssh -V 2>&1 | head -n1)
    echo "SSH version after upgrade attempt: ${SSH_VERSION_AFTER}" | tee -a "${VALIDATION_LOG}"
fi

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

    # Disable tracing for SSH commands to avoid leaking sensitive data
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    # Try multiple SSH approaches to handle different OpenSSH versions and key formats
    local base_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=10"
    local ret=1
    local attempt=0

    # Approach 1: Standard modern SSH with primary key (supports OpenSSH format natively)
    ((attempt+=1))
    log "DEBUG: SSH Attempt ${attempt}: Standard SSH with primary key"
    output=$(ssh ${base_options} -i "${sshkey}" ${user}@${host} "${remote_cmd}" 2>&1)
    ret=$?
    if [[ $ret -eq 0 ]]; then
        log "DEBUG: SSH Attempt ${attempt} SUCCEEDED"
        return 0
    fi
    log "DEBUG: SSH Attempt ${attempt} FAILED - Return code: ${ret}"
    log "DEBUG: SSH Attempt ${attempt} Error: ${output}"

    if echo "$output" | grep -q "invalid format"; then
        log "DEBUG: Invalid key format detected, trying alternative approaches..."

        # Approach 2: Try PEM-converted keys if they exist
        for pem_key in /tmp/ssh-privatekey-pem{1,2,3}; do
            if [[ -f "$pem_key" ]]; then
                ((attempt+=1))
                log "DEBUG: SSH Attempt ${attempt}: Trying PEM key $(basename "$pem_key")"
                output=$(ssh ${base_options} -i "$pem_key" ${user}@${host} "${remote_cmd}" 2>&1)
                ret=$?
                if [[ $ret -eq 0 ]]; then
                    log "DEBUG: SSH Attempt ${attempt} SUCCEEDED with PEM key"
                    return 0
                fi
                log "DEBUG: SSH Attempt ${attempt} FAILED - Return code: ${ret}"
                log "DEBUG: SSH Attempt ${attempt} Error: ${output}"
            fi
        done

        # Approach 3: Add legacy crypto algorithms support with primary key
        ((attempt+=1))
        log "DEBUG: SSH Attempt ${attempt}: Primary key with legacy crypto options"
        output=$(ssh ${base_options} -o PubkeyAcceptedKeyTypes=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa -i "${sshkey}" ${user}@${host} "${remote_cmd}" 2>&1)
        ret=$?
        if [[ $ret -eq 0 ]]; then
            log "DEBUG: SSH Attempt ${attempt} SUCCEEDED with legacy crypto"
            return 0
        fi
        log "DEBUG: SSH Attempt ${attempt} FAILED - Return code: ${ret}"
        log "DEBUG: SSH Attempt ${attempt} Error: ${output}"

        # Approach 4: Try PEM keys with legacy crypto
        for pem_key in /tmp/ssh-privatekey-pem{1,2,3}; do
            if [[ -f "$pem_key" ]]; then
                ((attempt+=1))
                log "DEBUG: SSH Attempt ${attempt}: PEM key $(basename "$pem_key") with legacy crypto"
                output=$(ssh ${base_options} -o PubkeyAcceptedKeyTypes=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa -i "$pem_key" ${user}@${host} "${remote_cmd}" 2>&1)
                ret=$?
                if [[ $ret -eq 0 ]]; then
                    log "DEBUG: SSH Attempt ${attempt} SUCCEEDED with PEM key and legacy crypto"
                    return 0
                fi
                log "DEBUG: SSH Attempt ${attempt} FAILED - Return code: ${ret}"
                log "DEBUG: SSH Attempt ${attempt} Error: ${output}"
            fi
        done

        # Approach 5: Explicitly allow RSA with SHA variants
        ((attempt+=1))
        log "DEBUG: SSH Attempt ${attempt}: Primary key with PubkeyAcceptedAlgorithms"
        output=$(ssh ${base_options} -o PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-256,rsa-sha2-512 -i "${sshkey}" ${user}@${host} "${remote_cmd}" 2>&1)
        ret=$?
        if [[ $ret -eq 0 ]]; then
            log "DEBUG: SSH Attempt ${attempt} SUCCEEDED with PubkeyAcceptedAlgorithms"
            return 0
        fi
        log "DEBUG: SSH Attempt ${attempt} FAILED - Return code: ${ret}"
        log "DEBUG: SSH Attempt ${attempt} Error: ${output}"

        log "DEBUG: All ${attempt} SSH connection approaches failed"
    fi

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

# Log cluster profile information (critical for diagnosing key format issues)
log "Cluster Profile Directory: ${CLUSTER_PROFILE_DIR}"
if [[ -n "${CLUSTER_TYPE:-}" ]]; then
    log "Cluster Type: ${CLUSTER_TYPE}"
fi
# Try to identify the specific cluster profile from the path
if [[ "${CLUSTER_PROFILE_DIR}" =~ /([^/]+)$ ]]; then
    PROFILE_NAME="${BASH_REMATCH[1]}"
    log "Cluster Profile Name: ${PROFILE_NAME}"
fi
log ""

# Debug SSH key format
log "DEBUG: Checking SSH private key..."
if [[ -f "${SSH_PRIV_KEY_PATH}" ]]; then
    log "DEBUG: SSH key file exists"
    log "DEBUG: SSH key permissions: $(stat -c '%a' "${SSH_PRIV_KEY_PATH}" 2>/dev/null || stat -f '%Lp' "${SSH_PRIV_KEY_PATH}" 2>/dev/null)"
    log "DEBUG: SSH key first line: $(head -n1 "${SSH_PRIV_KEY_PATH}")"
    log "DEBUG: SSH key file size: $(wc -c < "${SSH_PRIV_KEY_PATH}") bytes"

    # Check if key is in new OpenSSH format and needs conversion
    if head -n1 "${SSH_PRIV_KEY_PATH}" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
        log "DEBUG: Key is in OpenSSH format, may need conversion to PEM for older SSH clients"
        log "DEBUG: Attempting to use key as-is first..."
    elif head -n1 "${SSH_PRIV_KEY_PATH}" | grep -q "BEGIN.*PRIVATE KEY"; then
        log "DEBUG: Key appears to be in PEM format"
    else
        log "DEBUG: WARNING: Key format not recognized"
    fi
else
    log "DEBUG: ERROR: SSH key file does not exist at ${SSH_PRIV_KEY_PATH}"
fi

# Fix SSH key permissions - SSH clients reject keys with overly permissive permissions
# The cluster-profile SSH key is mounted read-only, so copy it to a writable location
# Try multiple conversion approaches to handle different GCP quota slice environments
if [[ -f "${SSH_PRIV_KEY_PATH}" ]]; then
    log "DEBUG: Preparing SSH key with multiple format options..."

    # Primary key: original format with fixed permissions
    WRITABLE_SSH_KEY="/tmp/ssh-privatekey"
    cp "${SSH_PRIV_KEY_PATH}" "${WRITABLE_SSH_KEY}"
    chmod 600 "${WRITABLE_SSH_KEY}"
    log "DEBUG: Primary key format: $(head -n1 "${WRITABLE_SSH_KEY}")"

    # If key is in OpenSSH format, create PEM variants using different methods
    if head -n1 "${WRITABLE_SSH_KEY}" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
        log "DEBUG: Key is in OpenSSH format, creating PEM conversion variants..."

        # Check if ssh-keygen supports -m PEM
        if ! command -v ssh-keygen &>/dev/null; then
            log "ERROR: ssh-keygen command not found, cannot convert key"
        elif ! ssh-keygen -m PEM 2>&1 | grep -qE "(PEM|illegal option|usage)"; then
            log "WARNING: ssh-keygen does not appear to support -m PEM flag"
        fi

        # Method 1: ssh-keygen with -P/-N flags
        PEM_KEY_1="/tmp/ssh-privatekey-pem1"
        cp "${WRITABLE_SSH_KEY}" "${PEM_KEY_1}"
        log "DEBUG: Attempting Method 1 (ssh-keygen -p -m PEM -P \"\" -N \"\" -f \"${PEM_KEY_1}\")..."
        CONVERSION_OUTPUT=$(ssh-keygen -p -m PEM -P "" -N "" -f "${PEM_KEY_1}" 2>&1)
        CONVERSION_RET=$?
        if [[ ${CONVERSION_RET} -eq 0 ]]; then
            KEY_HEADER=$(head -n1 "${PEM_KEY_1}")
            log "DEBUG: Method 1 SUCCESS - Return code: ${CONVERSION_RET}"
            log "DEBUG: Method 1 output: ${CONVERSION_OUTPUT}"
            log "DEBUG: Method 1 converted key format: ${KEY_HEADER}"
            if [[ "${KEY_HEADER}" == *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
                log "WARNING: Method 1 returned success but key is still in OpenSSH format (conversion may have failed silently)"
                rm -f "${PEM_KEY_1}"
            fi
        else
            rm -f "${PEM_KEY_1}"
            log "DEBUG: Method 1 FAILED - Return code: ${CONVERSION_RET}"
            log "DEBUG: Method 1 error output: ${CONVERSION_OUTPUT}"
        fi

        # Method 2: ssh-keygen with piped passphrases
        PEM_KEY_2="/tmp/ssh-privatekey-pem2"
        cp "${WRITABLE_SSH_KEY}" "${PEM_KEY_2}"
        log "DEBUG: Attempting Method 2 ((echo \"\"; echo \"\") | ssh-keygen -p -m PEM -f \"${PEM_KEY_2}\")..."
        CONVERSION_OUTPUT=$( (echo ""; echo "") | ssh-keygen -p -m PEM -f "${PEM_KEY_2}" 2>&1)
        CONVERSION_RET=$?
        if [[ ${CONVERSION_RET} -eq 0 ]]; then
            chmod 600 "${PEM_KEY_2}"
            KEY_HEADER=$(head -n1 "${PEM_KEY_2}")
            log "DEBUG: Method 2 SUCCESS - Return code: ${CONVERSION_RET}"
            log "DEBUG: Method 2 output: ${CONVERSION_OUTPUT}"
            log "DEBUG: Method 2 converted key format: ${KEY_HEADER}"
            if [[ "${KEY_HEADER}" == *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
                log "WARNING: Method 2 returned success but key is still in OpenSSH format (conversion may have failed silently)"
                rm -f "${PEM_KEY_2}"
            fi
        else
            rm -f "${PEM_KEY_2}"
            log "DEBUG: Method 2 FAILED - Return code: ${CONVERSION_RET}"
            log "DEBUG: Method 2 error output: ${CONVERSION_OUTPUT}"
        fi

        # Method 3: ssh-keygen with heredoc
        PEM_KEY_3="/tmp/ssh-privatekey-pem3"
        cp "${WRITABLE_SSH_KEY}" "${PEM_KEY_3}"
        log "DEBUG: Attempting Method 3 (ssh-keygen -p -m PEM -f \"${PEM_KEY_3}\" <<< \$'\\n\\n')..."
        CONVERSION_OUTPUT=$(ssh-keygen -p -m PEM -f "${PEM_KEY_3}" <<< $'\n\n' 2>&1)
        CONVERSION_RET=$?
        if [[ ${CONVERSION_RET} -eq 0 ]]; then
            chmod 600 "${PEM_KEY_3}"
            KEY_HEADER=$(head -n1 "${PEM_KEY_3}")
            log "DEBUG: Method 3 SUCCESS - Return code: ${CONVERSION_RET}"
            log "DEBUG: Method 3 output: ${CONVERSION_OUTPUT}"
            log "DEBUG: Method 3 converted key format: ${KEY_HEADER}"
            if [[ "${KEY_HEADER}" == *"BEGIN OPENSSH PRIVATE KEY"* ]]; then
                log "WARNING: Method 3 returned success but key is still in OpenSSH format (conversion may have failed silently)"
                rm -f "${PEM_KEY_3}"
            fi
        else
            rm -f "${PEM_KEY_3}"
            log "DEBUG: Method 3 FAILED - Return code: ${CONVERSION_RET}"
            log "DEBUG: Method 3 error output: ${CONVERSION_OUTPUT}"
        fi

        # Summary of conversion attempts
        SUCCESSFUL_CONVERSIONS=0
        [[ -f "${PEM_KEY_1}" ]] && ((SUCCESSFUL_CONVERSIONS+=1))
        [[ -f "${PEM_KEY_2}" ]] && ((SUCCESSFUL_CONVERSIONS+=1))
        [[ -f "${PEM_KEY_3}" ]] && ((SUCCESSFUL_CONVERSIONS+=1))
        log "DEBUG: PEM conversion summary: ${SUCCESSFUL_CONVERSIONS}/3 methods succeeded"
    fi

    # Use the primary key for all SSH operations
    SSH_PRIV_KEY_PATH="${WRITABLE_SSH_KEY}"
fi
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
