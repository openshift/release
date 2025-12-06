#!/bin/bash

# E2E Test Step - Builds QEMU VM image and executes attestation tests
set -o nounset
set -o pipefail
# Note: Not setting -e to allow custom error handling

# ============================================================================
# Prow CI Standard Environment Variables Check
# ============================================================================

if [ -z "${SHARED_DIR:-}" ]; then
  echo "[ERROR] SHARED_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

if [ -z "${ARTIFACT_DIR:-}" ]; then
  echo "[ERROR] ARTIFACT_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

echo "=========================================="
echo "CoCl Operator E2E Tests - Starting"
echo "=========================================="
echo "This script builds QEMU VM image and runs attestation tests"
echo "=========================================="
date

# ============================================================================
# Prow CI User Environment Setup
# ============================================================================

if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "[INFO] Creating user entry for UID $(id -u) in /etc/passwd"
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "[WARN] Cannot write to /etc/passwd, SSH may encounter issues"
  fi
fi

if whoami &> /dev/null; then
  echo "[INFO] Current user: $(whoami) (UID: $(id -u))"
else
  echo "[WARN] User still not resolvable, continuing anyway"
fi

# ============================================================================
# Global Variables and Configuration
# ============================================================================

# Test execution status tracking
TEST_STATUS=0
CRITICAL_FAILURE=false

# Configurable timeouts and parameters
E2E_TEST_TIMEOUT="${E2E_TEST_TIMEOUT:-1800}"
VM_BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-600}"

# FCOS image configuration
FCOS_SOURCE_IMAGE="${FCOS_SOURCE_IMAGE:-quay.io/trusted-execution-clusters/fedora-coreos:42.20250705.3.0}"
FCOS_TARGET_IMAGE="${FCOS_TARGET_IMAGE:-quay.io/trusted-execution-clusters/fcos}"

# Investigations repository
INVESTIGATIONS_REPO="${INVESTIGATIONS_REPO:-https://github.com/trusted-execution-clusters/investigations.git}"
INVESTIGATIONS_BRANCH="${INVESTIGATIONS_BRANCH:-main}"

# Progress tracking
TOTAL_STEPS=6
CURRENT_STEP=0

# ============================================================================
# Helper Functions
# ============================================================================

progress() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo ""
  echo "=========================================="
  echo "Step ${CURRENT_STEP}/${TOTAL_STEPS}: $1"
  echo "=========================================="
}

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1"
}

log_success() {
  echo "[SUCCESS] $1"
}

# ============================================================================
# Read Configuration from Previous Step
# ============================================================================

progress "Reading configuration from previous step"

if [ ! -f "${SHARED_DIR}/beaker_info" ]; then
  log_error "beaker_info not found. Previous steps must run first."
  exit 1
fi

source "${SHARED_DIR}/beaker_info"

log_info "=== Configuration Summary ==="
log_info "Beaker machine: ${BEAKER_IP}"
log_info "Beaker user: ${BEAKER_USER}"
log_info "E2E test timeout: ${E2E_TEST_TIMEOUT}s"
log_info "VM boot timeout: ${VM_BOOT_TIMEOUT}s"
log_info "FCOS source image: ${FCOS_SOURCE_IMAGE}"
log_info ""

# ============================================================================
# SSH Key Setup
# ============================================================================

progress "Setting up SSH key"

SSH_PKEY_PATH_VAULT="/var/run/beaker-bm/beaker-ssh-private-key"

if [ -f "${SSH_PKEY_PATH_VAULT}" ]; then
  SSH_PKEY_PATH="${SSH_PKEY_PATH_VAULT}"
  log_info "Using SSH key from Vault: ${SSH_PKEY_PATH_VAULT}"
elif [ -n "${CLUSTER_PROFILE_DIR:-}" ] && [ -f "${CLUSTER_PROFILE_DIR}/ssh-key" ]; then
  SSH_PKEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-key"
  log_info "Using SSH key from CLUSTER_PROFILE_DIR: ${CLUSTER_PROFILE_DIR}/ssh-key"
else
  log_error "SSH key not found at ${SSH_PKEY_PATH_VAULT}"
  exit 1
fi

SSH_PKEY="${HOME}/.ssh/beaker_key"
mkdir -p "${HOME}/.ssh"
cp "${SSH_PKEY_PATH}" "${SSH_PKEY}"
chmod 600 "${SSH_PKEY}"
log_info "SSH private key configured at ${SSH_PKEY}"

# ============================================================================
# SSH Options Configuration
# ============================================================================

progress "Configuring SSH connection"

SSHOPTS=(
  -o 'ConnectTimeout=120'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=30'
  -o 'ServerAliveCountMax=5'
  -o 'LogLevel=ERROR'
  -i "${SSH_PKEY}"
)

log_info "SSH connection timeout set to 120 seconds to accommodate slow network"

# ============================================================================
# SSH Connection Test with Retry
# ============================================================================

progress "Establishing SSH connection to Beaker machine"

log_info "Testing SSH connection to ${BEAKER_USER}@${BEAKER_IP}..."

MAX_SSH_ATTEMPTS=15
BASE_RETRY_DELAY=5

for attempt in $(seq 1 $MAX_SSH_ATTEMPTS); do
  RETRY_DELAY=$((BASE_RETRY_DELAY * attempt / 3))
  [ $RETRY_DELAY -gt 30 ] && RETRY_DELAY=30

  # Test SSH connectivity
  if [[ $attempt -eq 1 ]]; then
    log_info "[DEBUG] First SSH attempt with verbose debugging (-vvv)..."
    if ssh -vvv "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "echo 'SSH test successful'; hostname; uptime" 2>&1 | tee /tmp/ssh-debug.log; then
      log_success "SSH connection established after ${attempt} attempt(s)"
      break
    else
      log_error "[DEBUG] SSH verbose output (last 50 lines):"
      tail -50 /tmp/ssh-debug.log || true
      log_warn "SSH connection failed, attempt ${attempt}/${MAX_SSH_ATTEMPTS}. Retrying in ${RETRY_DELAY} seconds..."
      sleep $RETRY_DELAY
    fi
  else
    if ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "echo 'SSH test successful'; hostname; uptime"; then
      log_success "SSH connection established after ${attempt} attempt(s)"
      break
    else
      if [[ $attempt -eq $MAX_SSH_ATTEMPTS ]]; then
        log_error "Failed to establish SSH connection after ${MAX_SSH_ATTEMPTS} attempts"
        log_error "Sleeping for 1800 seconds to allow pod debugging..."
        sleep 1800
        CRITICAL_FAILURE=true
        TEST_STATUS=1
        exit 1
      fi
      log_warn "SSH connection failed, attempt ${attempt}/${MAX_SSH_ATTEMPTS}. Retrying in ${RETRY_DELAY} seconds..."
      sleep $RETRY_DELAY
    fi
  fi
done

# ============================================================================
# Execute E2E Tests on Beaker Machine
# ============================================================================

progress "Executing E2E tests on Beaker machine"

log_info "Running E2E test script on Beaker machine..."
log_info "Timeout: ${E2E_TEST_TIMEOUT} seconds"

if ! timeout "${E2E_TEST_TIMEOUT}" ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${FCOS_SOURCE_IMAGE}" "${FCOS_TARGET_IMAGE}" \
  "${INVESTIGATIONS_REPO}" "${INVESTIGATIONS_BRANCH}" \
  "${VM_BOOT_TIMEOUT}" << 'EOF'

set -euo pipefail
set -x

FCOS_SOURCE_IMAGE="$1"
FCOS_TARGET_IMAGE="$2"
INVESTIGATIONS_REPO="$3"
INVESTIGATIONS_BRANCH="$4"
VM_BOOT_TIMEOUT="$5"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Date: $(date)"
echo "=========================================="
echo "[DEBUG] Received SSH parameters:"
echo "  FCOS_SOURCE_IMAGE: ${FCOS_SOURCE_IMAGE}"
echo "  FCOS_TARGET_IMAGE: ${FCOS_TARGET_IMAGE}"
echo "  INVESTIGATIONS_REPO: ${INVESTIGATIONS_REPO}"
echo "  INVESTIGATIONS_BRANCH: ${INVESTIGATIONS_BRANCH}"
echo "  VM_BOOT_TIMEOUT: ${VM_BOOT_TIMEOUT}"
echo "=========================================="

# Create log directory
mkdir -p /tmp/e2e-test-logs
exec > >(tee -a /tmp/e2e-test-logs/e2e-test.log)
exec 2>&1

# ============================================================================
# Part 1: Build QEMU VM Image (from e2e-build-image-for-qemu-vm)
# ============================================================================

echo "[INFO] =========================================="
echo "[INFO] Part 1: Building QEMU VM Image"
echo "[INFO] =========================================="

# Install dependencies
echo "[INFO] Installing build dependencies..."

sudo dnf update -y
sudo dnf install -y \
    git \
    just \
    podman \
    skopeo \
    osbuild \
    osbuild-tools \
    osbuild-ostree \
    jq \
    xfsprogs \
    e2fsprogs \
    dosfstools \
    genisoimage \
    squashfs-tools \
    erofs-utils \
    syslinux-nonlinux

echo "[SUCCESS] Build dependencies installed"

# Set SELinux to permissive mode
echo "[INFO] Setting SELinux to permissive mode..."
sudo setenforce 0 || true
sudo sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Clone investigations repository
INVESTIGATIONS_DIR="${HOME}/investigations"
if [ -d "${INVESTIGATIONS_DIR}" ]; then
  echo "[INFO] Investigations directory already exists, removing..."
  rm -rf "${INVESTIGATIONS_DIR}"
fi

echo "[INFO] Cloning investigations repository..."
git clone --branch "${INVESTIGATIONS_BRANCH}" "${INVESTIGATIONS_REPO}" "${INVESTIGATIONS_DIR}"
cd "${INVESTIGATIONS_DIR}"

# Reset to specific commit that contains required scripts
echo "[INFO] Resetting to commit 7378bacbad92020 (contains required VM scripts)..."
git reset --hard 7378bacbad92020
echo "[SUCCESS] Repository reset to working commit"

# Verify required scripts exist
echo "[INFO] Verifying required scripts exist..."
if [ -f "scripts/create-existing-trustee-vm.sh" ]; then
    echo "[SUCCESS] scripts/create-existing-trustee-vm.sh found"
else
    echo "[ERROR] scripts/create-existing-trustee-vm.sh not found after reset"
    echo "[INFO] Current commit: $(git rev-parse HEAD)"
    echo "[INFO] Available scripts:"
    ls -la scripts/ 2>/dev/null || echo "scripts/ directory not found"
    exit 1
fi

# Pull FCOS container image
echo "[INFO] Pulling FCOS container image..."
sudo podman pull "${FCOS_SOURCE_IMAGE}"

# Tag image for build scripts
echo "[INFO] Tagging image as ${FCOS_TARGET_IMAGE}..."
sudo podman tag "${FCOS_SOURCE_IMAGE}" "${FCOS_TARGET_IMAGE}"

# Navigate to coreos directory
cd coreos

# Define image paths
QEMU_IMAGE_NAME="fcos-qemu.x86_64.qcow2"
LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"
FINAL_IMAGE_PATH="${LIBVIRT_IMAGE_DIR}/${QEMU_IMAGE_NAME}"

# Ensure libvirt image directory exists
sudo mkdir -p "${LIBVIRT_IMAGE_DIR}"

# Check for existing image
if [ -f "${FINAL_IMAGE_PATH}" ]; then
    echo "[INFO] Existing QEMU image found at ${FINAL_IMAGE_PATH}, skipping build."
else
    echo "[INFO] Creating OCI archive..."
    just oci-archive

    echo "[INFO] Building QEMU image..."
    just osbuild-qemu

    echo "[INFO] Moving built image to ${LIBVIRT_IMAGE_DIR}..."
    sudo mv "${QEMU_IMAGE_NAME}" "${LIBVIRT_IMAGE_DIR}/"
    echo "[SUCCESS] Build complete! Image at ${FINAL_IMAGE_PATH}"
fi

# ============================================================================
# Part 2: Start VM and Run Attestation Tests (from e2e-start-vm)
# ============================================================================

echo ""
echo "[INFO] =========================================="
echo "[INFO] Part 2: Starting VM and Running Attestation Tests"
echo "[INFO] =========================================="

# Function: check_vm_boot
check_vm_boot() {
    local VM_NAME="$1"
    local MAX_RETRIES=$((VM_BOOT_TIMEOUT / 5))
    local SLEEP_INTERVAL=5
    local IP

    echo "[INFO] Attempting to get IP for VM: $VM_NAME..."

    for i in $(seq 1 $MAX_RETRIES); do
        IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {split($4, a, "/"); print a[1]}')

        if [[ -n "$IP" ]]; then
            echo "[INFO] VM IP detected: $IP"
            break
        fi
        echo "[INFO] Waiting for VM IP... (${i}/${MAX_RETRIES})"
        sleep $SLEEP_INTERVAL
    done

    if [[ -z "$IP" ]]; then
        echo "[ERROR] Failed to get IP address for VM: $VM_NAME"
        return 1
    fi

    echo "[INFO] Waiting for SSH port 22 on $IP..."

    for i in $(seq 1 $MAX_RETRIES); do
        if nc -zv "$IP" 22 >/dev/null 2>&1; then
            echo "[SUCCESS] SSH port 22 is open. VM boot completed."
            return 0
        fi
        echo "[INFO] Waiting for SSH port... (${i}/${MAX_RETRIES})"
        sleep $SLEEP_INTERVAL
    done

    echo "[ERROR] Timeout: VM did not open port 22 in expected time."
    return 1
}

# Function: check_attestation_strict
check_attestation_strict() {
    local LOGFILE="$1"

    if [ ! -f "$LOGFILE" ]; then
        echo "[ERROR] Log file not found: $LOGFILE"
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
    echo "============================================="

    if [[ $ALL_ATTEST -eq 0 ]]; then
        echo "[ERROR] No /attest requests found"
        return 1
    elif [[ $ALL_ATTEST -ne $ATTEST_200 ]]; then
        echo "[ERROR] Some /attest requests failed (non-200)"
        return 1
    elif [[ $ATTEST_200 -ne $RESOURCE_200 ]]; then
        echo "[ERROR] /attest count and /resource count do not match"
        return 1
    else
        echo "[SUCCESS] All attestations succeeded and resources fetched"
        return 0
    fi
}

# Navigate back to investigations directory
cd "${INVESTIGATIONS_DIR}"

# Prerequisites check
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root."
    exit 1
fi

if ! command -v virt-install &> /dev/null; then
    echo "[INFO] virt-install not found. Installing..."
    yum install -y virt-install
fi

# SSH key setup
SSH_KEY_PATH="/root/.ssh/id_ed25519.pub"
if [ ! -f "${SSH_KEY_PATH}" ]; then
    echo "[INFO] SSH key not found at ${SSH_KEY_PATH}. Creating..."
    mkdir -p "$(dirname "${SSH_KEY_PATH}")"
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH%.pub}" -N ""
fi

# Prepare VM Image
SOURCE_IMAGE_PATH="coreos/fcos-qemu.x86_64.qcow2"
DEST_IMAGE_PATH="/var/lib/libvirt/images/fcos-qemu.x86_64.qcow2"

if [ -f "${SOURCE_IMAGE_PATH}" ]; then
    echo "[INFO] Moving VM image to /var/lib/libvirt/images..."
    mv "${SOURCE_IMAGE_PATH}" "${DEST_IMAGE_PATH}"
elif [ ! -f "${DEST_IMAGE_PATH}" ]; then
    echo "[ERROR] VM image not found at ${SOURCE_IMAGE_PATH} or ${DEST_IMAGE_PATH}."
    exit 1
fi

# Apply configuration patches
echo "[INFO] Applying configuration patches..."

# Patch create-existing-trustee-vm.sh if it exists
if [ -f "scripts/create-existing-trustee-vm.sh" ]; then
    echo "[INFO] Patching scripts/create-existing-trustee-vm.sh..."
    sed -i 's|CUSTOM_IMAGE="$(pwd)/fcos-cvm-qemu.x86_64.qcow2"|CUSTOM_IMAGE="/var/lib/libvirt/images/fcos-qemu.x86_64.qcow2"|' "scripts/create-existing-trustee-vm.sh"
    echo "[SUCCESS] scripts/create-existing-trustee-vm.sh patched"
else
    echo "[WARN] scripts/create-existing-trustee-vm.sh not found, skipping patch"
fi

# Patch luks.bu if it exists
if [ -f "configs/luks.bu" ]; then
    echo "[INFO] Patching configs/luks.bu..."

    # Debug: show original content around line 15
    echo "[DEBUG] Original configs/luks.bu content around line 15:"
    sed -n '10,20p' "configs/luks.bu" || true

    # More careful replacement - preserve YAML structure
    # Replace <IP> placeholder with actual IP, and update ignition path
    sed -i 's|http://<IP>:8000/pin-trustee\.ign|http://192.168.122.1:8000/ignition-clevis-pin-trustee|' "configs/luks.bu"

    # Debug: show patched content
    echo "[DEBUG] Patched configs/luks.bu content around line 15:"
    sed -n '10,20p' "configs/luks.bu" || true

    # Verify the file is still valid YAML (basic check)
    if command -v yamllint &>/dev/null; then
        yamllint configs/luks.bu || echo "[WARN] YAML validation failed, but continuing..."
    fi

    echo "[SUCCESS] configs/luks.bu patched"
else
    echo "[WARN] configs/luks.bu not found, skipping patch"
fi

# Patch install_vm.sh
INSTALL_VM_SCRIPT="scripts/install_vm.sh"

if [ -f "$INSTALL_VM_SCRIPT" ]; then
    echo "[INFO] Patching install_vm.sh - Fix 1: Replace butane image registry..."
    # Fix 1: Replace confidential-clusters with trusted-execution-clusters
    sed -i 's|quay.io/confidential-clusters/butane:clevis-pin-trustee|quay.io/trusted-execution-clusters/butane:clevis-pin-trustee|g' "$INSTALL_VM_SCRIPT"
    echo "[SUCCESS] Butane image registry updated"

    echo "[INFO] Patching install_vm.sh - Fix 2: Update IGNITION_CONFIG and add file copy..."

    # Fix 2 & 3 Combined: Add code to copy ignition file to /var/lib/libvirt/images
    # This needs to be inserted AFTER the ignition file is generated but BEFORE virt-install

    # First, find where to insert the copy command
    # Look for the line that assigns IGNITION_CONFIG or uses IGNITION_FILE
    if grep -q 'IGNITION_CONFIG=' "$INSTALL_VM_SCRIPT"; then
        echo "[INFO] Adding ignition file copy after IGNITION_CONFIG assignment..."

        # Insert code after the IGNITION_CONFIG line to copy file
        sed -i '/^IGNITION_CONFIG=/a\
\
# Copy ignition file to libvirt images directory (fixes permission issues)\
echo "[INFO] Copying ignition file to /var/lib/libvirt/images/..."\
echo "[DEBUG] Original IGNITION_FILE: ${IGNITION_FILE}"\
echo "[DEBUG] Current directory: $(pwd)"\
\
# Check if file already exists in target location\
IGNITION_FILENAME="${IGNITION_FILE##*/}"\
TARGET_IGNITION_PATH="/var/lib/libvirt/images/${IGNITION_FILENAME}"\
\
if [ -f "${TARGET_IGNITION_PATH}" ]; then\
    echo "[INFO] Ignition file already exists at target location: ${TARGET_IGNITION_PATH}"\
    IGNITION_CONFIG="${TARGET_IGNITION_PATH}"\
else\
    # Convert to absolute path if it is a relative path\
    if [[ "${IGNITION_FILE}" != /* ]]; then\
        IGNITION_FILE_ABS="$(pwd)/${IGNITION_FILE}"\
        echo "[DEBUG] Converted to absolute path: ${IGNITION_FILE_ABS}"\
    else\
        IGNITION_FILE_ABS="${IGNITION_FILE}"\
    fi\
\
    # Check if file exists at source location\
    if [ ! -f "${IGNITION_FILE_ABS}" ]; then\
        echo "[ERROR] Ignition file not found at source: ${IGNITION_FILE_ABS}"\
        echo "[INFO] Checking target location: ${TARGET_IGNITION_PATH}"\
        if [ -f "${TARGET_IGNITION_PATH}" ]; then\
            echo "[INFO] Found at target location, using it"\
            IGNITION_CONFIG="${TARGET_IGNITION_PATH}"\
        else\
            echo "[ERROR] Ignition file not found at either location"\
            ls -la "$(dirname ${IGNITION_FILE_ABS})" 2>/dev/null || echo "Source directory does not exist"\
            ls -la /var/lib/libvirt/images/ 2>/dev/null || echo "Target directory does not exist"\
            exit 1\
        fi\
    else\
        # Copy file to target location\
        mkdir -p /var/lib/libvirt/images\
        cp "${IGNITION_FILE_ABS}" "${TARGET_IGNITION_PATH}"\
        chcon --type svirt_home_t "${TARGET_IGNITION_PATH}" 2>/dev/null || true\
        IGNITION_CONFIG="${TARGET_IGNITION_PATH}"\
        echo "[INFO] Ignition file copied to: ${IGNITION_CONFIG}"\
    fi\
fi' "$INSTALL_VM_SCRIPT"

        echo "[SUCCESS] Ignition file copy code added"
    else
        echo "[WARN] IGNITION_CONFIG not found in script, cannot add copy code"
    fi

    echo "[INFO] Patching install_vm.sh - Fix 4: Console logging..."
    VM_NAME="${VM_NAME:-existing-trustee}"
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    FULL_LOG_DIR="/var/log/kbs_logs_${TIMESTAMP}"
    mkdir -p "$FULL_LOG_DIR"

    if ! grep -q 'serial file,path=' "$INSTALL_VM_SCRIPT"; then
        # Add console logging to virt-install command
        LOG_PATH="/var/lib/libvirt/images/${VM_NAME}.log"

        # Find the virt-install line and add serial console parameters
        # Insert as a new line after "virt-install" to avoid breaking existing parameters
        sed -i "/^[[:space:]]*virt-install/a\\    --serial pty \\\\" "$INSTALL_VM_SCRIPT"
        sed -i "/^[[:space:]]*--serial pty/a\\    --serial file,path=${LOG_PATH} \\\\" "$INSTALL_VM_SCRIPT"

        echo "[SUCCESS] Console logging added to install_vm.sh"
    else
        echo "[INFO] Console logging already present in install_vm.sh"
    fi
else
    echo "[WARN] $INSTALL_VM_SCRIPT not found, skipping patches"
    VM_NAME="${VM_NAME:-existing-trustee}"
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    FULL_LOG_DIR="/var/log/kbs_logs_${TIMESTAMP}"
    mkdir -p "$FULL_LOG_DIR"
fi

# Start VM
CREATE_VM_SCRIPT="scripts/create-existing-trustee-vm.sh"
if [ -f "${CREATE_VM_SCRIPT}" ]; then
    # Note: Ignition file copy/move is now handled by Fix 3 above (after butane command)
    # No need for additional patching here

    echo "[INFO] Starting VM..."
    sh "${CREATE_VM_SCRIPT}" "${SSH_KEY_PATH}"
else
    echo "[ERROR] VM creation script ${CREATE_VM_SCRIPT} not found."
    echo "[INFO] Listing scripts directory contents:"
    ls -la scripts/ 2>/dev/null || echo "scripts/ directory not found"
    echo "[INFO] Current directory: $(pwd)"
    echo "[INFO] Directory contents:"
    ls -la
    exit 1
fi
echo "[INFO] VM creation script finished."

# Check if VM booted successfully
if ! check_vm_boot "${VM_NAME}"; then
    echo "[ERROR] VM boot check failed."
    echo "[INFO] Dumping VM console log:"
    cat "/var/lib/libvirt/images/${VM_NAME}.log" || echo "Could not dump log."
    exit 1
fi

# Collect logs and check attestation
echo "[INFO] VM is up. Collecting logs for attestation check..."
NAMESPACE="confidential-clusters"
LOG_DIR="$FULL_LOG_DIR"
echo "[INFO] Logs will be collected under: $LOG_DIR"

# Collect pod logs
echo "[INFO] Collecting all pod logs for final verification..."
pods=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

if [ -z "$pods" ]; then
    echo "[ERROR] No running pods found in namespace $NAMESPACE."
    exit 1
fi

TRUSTEE_LOG=""
for pod in $pods; do
    logfile="$LOG_DIR/$pod.log"
    echo "[INFO] Collecting logs for pod: $pod"
    kubectl logs "$pod" -n "$NAMESPACE" > "$logfile" 2>&1
    if [[ $pod == trustee-deployment* ]]; then
        TRUSTEE_LOG="$logfile"
    fi
done

if [ -z "$TRUSTEE_LOG" ]; then
    echo "[ERROR] No trustee-deployment pod found."
    exit 1
fi

echo "[INFO] All logs collected under $LOG_DIR"

# Run attestation check
echo "[INFO] Running attestation check on trustee-deployment pod..."
if ! check_attestation_strict "$TRUSTEE_LOG"; then
    echo "[ERROR] Attestation check failed."
    exit 1
fi

echo "[SUCCESS] All E2E tests passed!"

EOF
then
  log_error "E2E test execution failed or timed out after ${E2E_TEST_TIMEOUT} seconds"
  CRITICAL_FAILURE=true
  TEST_STATUS=1
fi

# Check if tests failed
if $CRITICAL_FAILURE; then
  log_error "Critical failure during E2E test execution"

  # Collect logs
  mkdir -p "${ARTIFACT_DIR}/e2e-test-logs"
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/e2e-test-logs/*.log" \
    "${ARTIFACT_DIR}/e2e-test-logs/" 2>&1 || log_warn "Failed to collect E2E test logs"

  # Try to collect KBS logs
  scp -r "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/var/log/kbs_logs_*/" \
    "${ARTIFACT_DIR}/e2e-test-logs/" 2>&1 || log_warn "Failed to collect KBS logs"

  exit ${TEST_STATUS}
fi

log_success "E2E tests completed successfully"

# ============================================================================
# Collect Test Logs and Artifacts
# ============================================================================

progress "Collecting test logs and artifacts"

mkdir -p "${ARTIFACT_DIR}/e2e-test-logs"
mkdir -p "${ARTIFACT_DIR}/e2e-test-reports"

# Collect E2E test logs
scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/e2e-test-logs/*.log" \
  "${ARTIFACT_DIR}/e2e-test-logs/" 2>&1 || log_warn "Failed to collect E2E test logs"

# Collect KBS logs
scp -r "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/var/log/kbs_logs_*/" \
  "${ARTIFACT_DIR}/e2e-test-logs/" 2>&1 || log_warn "Failed to collect KBS logs"

# Collect VM console logs
scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/var/lib/libvirt/images/*.log" \
  "${ARTIFACT_DIR}/e2e-test-logs/" 2>&1 || log_warn "Failed to collect VM console logs"

# Collect cluster state
if [ -f "${SHARED_DIR}/kubeconfig" ]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"

  log_info "Collecting cluster state..."
  kubectl get all -A > "${ARTIFACT_DIR}/e2e-test-logs/cluster-all-resources.yaml" 2>&1 || true
  kubectl get pods -n confidential-clusters -o yaml > "${ARTIFACT_DIR}/e2e-test-logs/operator-pods.yaml" 2>&1 || true
  kubectl get pods -n confidential-clusters -o wide > "${ARTIFACT_DIR}/e2e-test-logs/operator-pods-wide.txt" 2>&1 || true

  log_success "Cluster state collected"
else
  log_warn "kubeconfig not found, skipping cluster state collection"
fi

# Generate test report
cat > "${ARTIFACT_DIR}/e2e-test-reports/test-summary.txt" << REPORT
========================================
E2E Test Execution Summary
========================================
Date: $(date)
Cluster: ${KIND_CLUSTER_NAME:-kind}
Beaker Machine: ${BEAKER_IP}
Test Status: PASSED

Test Components:
1. QEMU VM Image Build: PASSED
2. VM Boot and Attestation: PASSED
3. Trustee Pod Verification: PASSED

Logs collected to: ${ARTIFACT_DIR}/e2e-test-logs/
========================================
REPORT

log_success "All test artifacts collected"

# ============================================================================
# Final Status
# ============================================================================

echo ""
echo "=========================================="
echo "CoCl Operator E2E Tests - Completed Successfully"
echo "=========================================="
echo "Beaker Machine: ${BEAKER_IP}"
echo ""
echo "All attestation tests passed"
echo ""
echo "Logs collected to: ${ARTIFACT_DIR}/e2e-test-logs/"
echo "Reports: ${ARTIFACT_DIR}/e2e-test-reports/"
echo "=========================================="
date
