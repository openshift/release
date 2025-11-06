#!/bin/bash

# Kind Cluster Creation Step - Executes make cluster-up on Beaker machine
set -o nounset
set -o pipefail
# Note: Not setting -e to allow custom error handling

# ============================================================================
# Prow CI Standard Environment Variables Check
# ============================================================================
# Prow CI sets these variables automatically, but verify they exist
# to comply with 'set -o nounset'

if [ -z "${SHARED_DIR:-}" ]; then
  echo "[ERROR] SHARED_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

if [ -z "${ARTIFACT_DIR:-}" ]; then
  echo "[ERROR] ARTIFACT_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

echo "=========================================="
echo "Kind Cluster Creation - Starting"
echo "=========================================="
echo "This script creates a Kind cluster on Beaker machine using make cluster-up"
echo "=========================================="
date

# ============================================================================
# Prow CI User Environment Setup
# ============================================================================
# Prow CI containers run with random UIDs. SSH and other tools require
# a valid user entry in /etc/passwd. Create one if it doesn't exist.

if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "[INFO] Creating user entry for UID $(id -u) in /etc/passwd"
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "[WARN] Cannot write to /etc/passwd, SSH may encounter issues"
  fi
fi

# Verify user is now resolvable
if whoami &> /dev/null; then
  echo "[INFO] Current user: $(whoami) (UID: $(id -u))"
else
  echo "[WARN] User still not resolvable, continuing anyway"
fi

# ============================================================================
# Global Variables and Configuration
# ============================================================================

# Deployment status tracking
DEPLOYMENT_STATUS=0
CRITICAL_FAILURE=false

# Configurable timeouts
CLUSTER_CREATE_TIMEOUT="${CLUSTER_CREATE_TIMEOUT:-900}"

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
  log_error "beaker_info not found. The beaker-kind-provision step must run first."
  exit 1
fi

source "${SHARED_DIR}/beaker_info"

log_info "Beaker machine: ${BEAKER_IP}"
log_info "Beaker user: ${BEAKER_USER}"
log_info "Kind cluster name: ${KIND_CLUSTER_NAME}"
log_info "Container runtime: ${CONTAINER_RUNTIME}"

# ============================================================================
# SSH Key Setup
# ============================================================================

progress "Setting up SSH key"

# Read SSH key from Vault-mounted secret
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
        DEPLOYMENT_STATUS=1
        exit 1
      fi
      log_warn "SSH connection failed, attempt ${attempt}/${MAX_SSH_ATTEMPTS}. Retrying in ${RETRY_DELAY} seconds..."
      sleep $RETRY_DELAY
    fi
  fi
done

# ============================================================================
# Create Kind Cluster on Beaker Machine
# ============================================================================

progress "Creating Kind cluster on Beaker machine"

log_info "Executing 'make cluster-up' on Beaker machine..."

if ! timeout "${CLUSTER_CREATE_TIMEOUT}" ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${KIND_CLUSTER_NAME}" "${CONTAINER_RUNTIME}" "${BEAKER_IP}" << 'EOF'

set -o nounset
set -o pipefail
set -x

KIND_CLUSTER_NAME="$1"
CONTAINER_RUNTIME="$2"
BEAKER_IP="$3"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Beaker IP: ${BEAKER_IP}"
echo "Runtime: ${CONTAINER_RUNTIME}"
echo "Cluster name: ${KIND_CLUSTER_NAME}"
echo "Date: $(date)"
echo "=========================================="

# Determine if sudo is needed
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  echo "[INFO] Running as root, sudo not needed"
else
  if command -v sudo &> /dev/null; then
    SUDO="sudo"
    echo "[INFO] Running as non-root user, using sudo"
  else
    echo "[WARN] Not running as root and sudo command not found, will try without sudo"
    SUDO=""
  fi
fi

# Create log directory
mkdir -p /tmp/kind-cluster-logs
exec > >(tee -a /tmp/kind-cluster-logs/cluster-creation.log)
exec 2>&1

# Navigate to cocl-operator directory
WORK_DIR="${HOME}/cocl-operator-kind-setup"
if [ ! -d "${WORK_DIR}" ]; then
  echo "[ERROR] cocl-operator directory not found: ${WORK_DIR}"
  echo "[ERROR] The beaker-kind-provision step must run first"
  exit 1
fi

cd "${WORK_DIR}"
echo "[INFO] Working directory: $(pwd)"

# Source environment variables for Rust and Go
if [ -f "/etc/profile.d/go.sh" ]; then
    source "/etc/profile.d/go.sh"
fi
if [ -f "/etc/profile.d/rust.sh" ]; then
    source "/etc/profile.d/rust.sh"
fi

# Set up the environment for make cluster-up
# Use 192.168.122.1 (libvirt default network) for internal-only access
export IP="192.168.122.1"
export RUNTIME="${CONTAINER_RUNTIME}"

echo "[INFO] Environment configured:"
echo "  IP=${IP} (libvirt internal network)"
echo "  RUNTIME=${RUNTIME}"
echo "  Note: Cluster will be accessible only from Beaker machine (internal network)"

# Execute make cluster-up
echo "[INFO] Executing: make cluster-up RUNTIME=${RUNTIME}"
if ! make cluster-up RUNTIME="${RUNTIME}"; then
  echo "[ERROR] 'make cluster-up' failed"
  exit 1
fi

echo "[SUCCESS] Kind cluster created successfully"

# Verify cluster is accessible
echo "[INFO] Verifying cluster access..."
export KUBECONFIG="${HOME}/.kube/config"

if ! kubectl cluster-info; then
  echo "[ERROR] Cannot access cluster"
  exit 1
fi

echo "[INFO] Checking node status..."
kubectl get nodes -o wide

# ============================================================================
# Reset Firewall Settings After Cluster Creation
# ============================================================================
# Kind cluster creation may have modified iptables rules via Docker
# Reset firewall settings to ensure SSH remains accessible for next step
echo ""
echo "[INFO] ==========================================="
echo "[INFO] Resetting Firewall After Cluster Creation"
echo "[INFO] ==========================================="

# Determine if sudo is needed
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# Stop firewalld (in case Docker restarted it)
echo "[INFO] Ensuring firewalld is stopped..."
${SUDO} systemctl stop firewalld 2>/dev/null || true

# Reset iptables default policies
echo "[INFO] Resetting iptables default policies to ACCEPT..."
${SUDO} iptables -P INPUT ACCEPT 2>/dev/null || true
${SUDO} iptables -P FORWARD ACCEPT 2>/dev/null || true
${SUDO} iptables -P OUTPUT ACCEPT 2>/dev/null || true

# Verify SSH protection service is still running
echo "[INFO] Verifying SSH protection service status..."
if ${SUDO} systemctl is-active ssh-protect.service >/dev/null 2>&1; then
    echo "[SUCCESS] SSH protection service is running"
else
    echo "[WARN] SSH protection service is not running, attempting to restart..."
    ${SUDO} systemctl start ssh-protect.service 2>/dev/null || true
    sleep 2
    if ${SUDO} systemctl is-active ssh-protect.service >/dev/null 2>&1; then
        echo "[SUCCESS] SSH protection service restarted successfully"
    else
        echo "[ERROR] SSH protection service failed to start"
        ${SUDO} journalctl -u ssh-protect.service --no-pager -n 20 || true
    fi
fi

# Display final iptables status for debugging
echo "[INFO] Current iptables default policies:"
${SUDO} iptables -L -n | head -20 || true

echo "[SUCCESS] Firewall reset completed"
echo "==========================================="

echo "[SUCCESS] Cluster is ready and accessible"

EOF
then
  log_error "Cluster creation failed or timed out after ${CLUSTER_CREATE_TIMEOUT} seconds"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=1
fi

# Check if cluster creation failed
if $CRITICAL_FAILURE; then
  log_error "Critical failure during cluster creation"

  # Collect logs
  mkdir -p "${ARTIFACT_DIR}/kind-cluster-logs"
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-cluster-logs/*.log" \
    "${ARTIFACT_DIR}/kind-cluster-logs/" 2>&1 || log_warn "Failed to collect cluster creation logs"

  exit ${DEPLOYMENT_STATUS}
fi

log_success "Kind cluster created successfully on Beaker machine"

# ============================================================================
# Note: Cluster is internal-only
# ============================================================================
# The Kind cluster is configured with IP=192.168.122.1 (libvirt internal network)
# It is accessible only from the Beaker machine itself, not from CI pod
# This is intentional - subsequent steps will execute operations via SSH on Beaker

# ============================================================================
# Collect Cluster Logs
# ============================================================================

progress "Collecting cluster creation logs"

mkdir -p "${ARTIFACT_DIR}/kind-cluster-logs"

scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-cluster-logs/*.log" \
  "${ARTIFACT_DIR}/kind-cluster-logs/" 2>&1 || log_warn "Failed to collect some logs"

# Collect cluster info
kubectl get all -A > "${ARTIFACT_DIR}/kind-cluster-logs/cluster-resources.yaml" 2>&1 || true
kubectl get nodes -o yaml > "${ARTIFACT_DIR}/kind-cluster-logs/nodes.yaml" 2>&1 || true

log_success "Logs collected to ${ARTIFACT_DIR}/kind-cluster-logs/"

# ============================================================================
# Final Status
# ============================================================================

echo ""
echo "=========================================="
echo "Kind Cluster Creation - Completed Successfully"
echo "=========================================="
echo "Cluster Name: ${KIND_CLUSTER_NAME}"
echo "Beaker Machine: ${BEAKER_IP}"
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo ""
echo "Kubeconfig: ${SHARED_DIR}/kubeconfig"
echo ""
echo "To access the cluster:"
echo "  export KUBECONFIG=${SHARED_DIR}/kubeconfig"
echo "  kubectl get nodes"
echo "=========================================="
date
