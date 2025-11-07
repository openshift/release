#!/usr/bin/env bash
# Prepares the environment, starts a trustee VM, checks for successful boot,
# and verifies attestation logs.
# Requires root privileges.

set -euo pipefail
set -x

# --- Function Definitions ---

# Test if the vm boot successfully
# Function: check_vm_boot
# Arguments:
#   $1 - VM name
# Returns:
#   0 if VM booted successfully (SSH port 22 open)
#   1 if timeout or failed to detect VM IP
check_vm_boot() {
    local VM_NAME="$1"
    local MAX_RETRIES=60
    local SLEEP_INTERVAL=5 # Increased sleep interval slightly
    local IP

    if [[ -z "$VM_NAME" ]]; then
        echo "Usage: check_vm_boot <vm-name>" >&2
        return 1
    fi

    echo "Attempting to get IP for VM: $VM_NAME..."

    # Loop to wait for IP address to be assigned
    for i in $(seq 1 $MAX_RETRIES); do
        # Get VM IP using virsh, without relying on guest agent or dynamic interface detection.
        # This directly parses the output of `virsh domifaddr $VM_NAME`.
        IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]}')
        
        if [[ -n "$IP" ]]; then
            echo "VM IP detected: $IP"
            break
        fi
        echo "Waiting for VM IP... (${i}/${MAX_RETRIES})"
        sleep $SLEEP_INTERVAL
    done

    if [[ -z "$IP" ]]; then
        echo "FAILURE: Failed to get IP address for VM: $VM_NAME"
        return 1
    fi

    echo "Waiting for SSH port 22 on $IP..."

    # Loop to check SSH port
    for i in $(seq 1 $MAX_RETRIES); do
        if nc -zv "$IP" 22 >/dev/null 2>&1; then
            echo "SUCCESS: SSH port 22 is open. VM boot completed."
            return 0
        fi
        echo "Waiting for SSH port... (${i}/${MAX_RETRIES})"
        sleep $SLEEP_INTERVAL
    done

    echo "FAILURE: Timeout: VM did not open port 22 in expected time."
    return 1
}

# Strict minimal attestation check function
check_attestation_strict() {
    local LOGFILE="$1"

    if [ ! -f "$LOGFILE" ]; then
        echo "FAILURE: Log file not found: $LOGFILE" >&2
        return 1
    fi

    local ALL_ATTEST
    ALL_ATTEST=$(grep 'POST /kbs/v0/attest' "$LOGFILE" | wc -l)

    local ATTEST_200
    ATTEST_200=$(grep 'POST /kbs/v0/attest HTTP/1.1" 200' "$LOGFILE" | wc -l)

    local RESOURCE_200
    RESOURCE_200=$(grep 'GET /kbs/v0/resource.*HTTP/1.1" 200' "$LOGFILE" | wc -l)

    echo "===== Strict Minimal Attestation Check ====="
    echo "Total POST /attest requests   : $ALL_ATTEST"
    echo "POST /attest HTTP 200 count   : $ATTEST_200"
    echo "GET /resource HTTP 200 count  : $RESOURCE_200"
    echo "==========================================="

    if [[ $ALL_ATTEST -eq 0 ]]; then
        echo "FAILURE: No /attest requests found"
        return 1
    elif [[ $ALL_ATTEST -ne $ATTEST_200 ]]; then
        echo "FAILURE: Some /attest requests failed (non-200)"
        return 1
    elif [[ $ATTEST_200 -ne $RESOURCE_200 ]]; then
        echo "FAILURE: /attest count and /resource count do not match"
        return 1
    else
        echo "SUCCESS: All attestations succeeded and resources fetched"
        return 0
    fi
}



# --- Main Script ---
# Navigate to the 'investigations' directory, which is expected to be a sibling
# to the current script's directory.
if [ ! -d "../investigations" ]; then
    echo "Error: 'investigations' directory not found at ../investigations. Exiting." >&2
    exit 1
fi
cd ../investigations

# 1. Prerequisites check
if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

if ! command -v virt-install &> /dev/null; then
    echo "Info: virt-install not found. Installing..."
    yum install -y virt-install
fi

SSH_KEY_PATH="/root/.ssh/id_ed25519.pub"
if [ ! -f "${SSH_KEY_PATH}" ]; then
    echo "Info: SSH key not found at ${SSH_KEY_PATH}. Creating..."
    mkdir -p "$(dirname "${SSH_KEY_PATH}")"
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH%.pub}" -N ""
fi

# 2. Prepare VM Image and Configs
SOURCE_IMAGE_PATH="coreos/fcos-qemu.x86_64.qcow2"
DEST_IMAGE_PATH="/var/lib/libvirt/images/fcos-qemu.x86_64.qcow2"

if [ -f "${SOURCE_IMAGE_PATH}" ]; then
    echo "Info: Moving VM image to /var/lib/libvirt/images..."
    mv "${SOURCE_IMAGE_PATH}" "${DEST_IMAGE_PATH}"
elif [ ! -f "${DEST_IMAGE_PATH}" ]; then
    echo "Error: VM image not found at ${SOURCE_IMAGE_PATH} or ${DEST_IMAGE_PATH}." >&2
    exit 1
fi

echo "Info: Applying configuration patches..."
# Update paths and IPs in config files
sed -i 's|CUSTOM_IMAGE="$(pwd)/fcos-cvm-qemu.x86_64.qcow2"|CUSTOM_IMAGE="/var/lib/libvirt/images/fcos-qemu.x86_64.qcow2"|' "scripts/create-existing-trustee-vm.sh"
sed -i 's|source: http://<IP>:8000/pin-trustee\.ign|source: http://192.168.122.1:8000/ignition-clevis-pin-trustee|' "configs/luks.bu"

# Patch install_vm.sh at runtime
INSTALL_VM_SCRIPT="scripts/install_vm.sh"

echo "Info: Patching install_vm.sh for IGNITION_CONFIG variable..."
sed -i 's|IGNITION_CONFIG="$(pwd)/${IGNITION_FILE}"|IGNITION_CONFIG="/var/lib/libvirt/images/${IGNITION_FILE##*/}"|' "$INSTALL_VM_SCRIPT"
echo "Info: IGNITION_CONFIG patched."

echo "Info: Patching install_vm.sh to add console logging..."
# Use VM_NAME from environment or default to 'existing-trustee'
VM_NAME="${VM_NAME:-existing-trustee}"
# Define a time-suffixed log directory under /var/log
TIMESTAMP=$(date +%Y%m%d%H%M%S)
FULL_LOG_DIR="/var/log/kbs_logs_${TIMESTAMP}"
mkdir -p "$FULL_LOG_DIR"

# Add PTY first, then file logging. Use double quotes for variable expansion.
if ! grep -q 'serial file,path=' "$INSTALL_VM_SCRIPT"; then
    sed -i "/virt-install/,/\"\${args\[@\]}\"/ s#\"\${args\[@\]}\"#& --serial pty --serial file,path=/var/lib/libvirt/images/${VM_NAME}.log#" "$INSTALL_VM_SCRIPT"
fi


# 3. Start VM
CREATE_VM_SCRIPT="scripts/create-existing-trustee-vm.sh"
if [ -f "${CREATE_VM_SCRIPT}" ]; then
    echo "Info: Patching install_vm.sh to move ignition file..."
    # Add commands to move the generated ignition file after the podman run command.
    sed -i '/"\\${butane_args\[@\]}" \/config.bu/a \
mkdir -p "\/var\/lib\/libvirt\/images" \
mv "${IGNITION_FILE}" "\/var\/lib\/libvirt\/images\/${IGNITION_FILE##*/}"' "$INSTALL_VM_SCRIPT"
    echo "Info: Ignition file move logic patched."
    echo "Info: Starting VM..."
    sh "${CREATE_VM_SCRIPT}" "${SSH_KEY_PATH}"
else
    echo "Error: VM creation script ${CREATE_VM_SCRIPT} not found." >&2
    exit 1
fi
echo "Info: VM creation script finished."

# 4. Check if VM booted successfully
if ! check_vm_boot "${VM_NAME}"; then
    echo "FAILURE: VM boot check failed."
    echo "Dumping VM console log:"
    cat "/var/lib/libvirt/images/${VM_NAME}.log" || echo "Could not dump log."
    exit 1
fi

# 5. Collect logs and check for attestation
echo "VM is up. Collecting logs for attestation check..."
NAMESPACE="trusted-execution-clusters"
LOG_DIR="$FULL_LOG_DIR"
echo "Logs will be collected under: $LOG_DIR"

# Re-collect logs to ensure we have the full picture
echo "Collecting all pod logs for final verification..."
pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -z "$pods" ]; then
    echo "FAILURE: No running pods found in namespace $NAMESPACE."
    exit 1
fi

TRUSTEE_LOG=""
for pod in $pods; do
    logfile="$LOG_DIR/$pod.log"
    echo "Collecting logs for pod: $pod"
    kubectl logs "$pod" -n "$NAMESPACE" > "$logfile" 2>&1
    if [[ $pod == trustee-deployment* ]]; then
        TRUSTEE_LOG="$logfile"
    fi
done

if [ -z "$TRUSTEE_LOG" ]; then
    echo "FAILURE: No trustee-deployment pod found after successful polling."
    exit 1
fi

echo "All logs collected under $LOG_DIR"

# Run attestation check on trustee pod logs
echo "Running final attestation check on trustee-deployment pod..."
if ! check_attestation_strict "$TRUSTEE_LOG"; then
    echo "FAILURE: Final attestation check failed."
    exit 1
fi

echo "SUCCESS: All checks passed."
