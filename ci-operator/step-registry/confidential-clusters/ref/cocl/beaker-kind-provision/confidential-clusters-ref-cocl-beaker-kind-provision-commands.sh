#!/bin/bash

# Enhanced version - adapted to use cocl-operator's kind setup
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
echo "Beaker Environment Preparation - Starting"
echo "=========================================="
echo "This script prepares the Beaker machine with:"
echo "  - Container runtime (docker/podman)"
echo "  - kubectl, kind, git"
echo "  - cocl-operator repository and configuration"
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
DOCKER_INSTALL_TIMEOUT="${DOCKER_INSTALL_TIMEOUT:-600}"
KIND_CREATE_TIMEOUT="${KIND_CREATE_TIMEOUT:-900}"
CLUSTER_READY_TIMEOUT="${CLUSTER_READY_TIMEOUT:-300}"

# cocl-operator configuration
COCL_OPERATOR_REPO="${COCL_OPERATOR_REPO:-https://github.com/trusted-execution-clusters/operator.git}"
COCL_OPERATOR_BRANCH="${COCL_OPERATOR_BRANCH:-main}"

# Progress tracking
TOTAL_STEPS=5  # Updated: removed cluster creation steps
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
# Environment Variables Check
# ============================================================================

progress "Checking environment variables"

# Beaker machine IP address
# Priority: environment variable > Vault secret > SHARED_DIR
if [ -z "${BEAKER_IP:-}" ]; then
  # Try reading from Vault secret first
  if [ -f "/var/run/beaker-bm/beaker-ip" ]; then
    BEAKER_IP=$(cat "/var/run/beaker-bm/beaker-ip")
    log_info "Read Beaker IP from Vault secret: ${BEAKER_IP}"
    # DEBUG: Print last octet of IP address for verification
    IP_LAST_OCTET="${BEAKER_IP##*.}"
    log_info "[DEBUG] IP last octet: ${IP_LAST_OCTET}"
  elif [ -f "${SHARED_DIR}/beaker_ip" ]; then
    BEAKER_IP=$(cat "${SHARED_DIR}/beaker_ip")
    log_info "Read Beaker IP from SHARED_DIR: ${BEAKER_IP}"
    # DEBUG: Print last octet of IP address for verification
    IP_LAST_OCTET="${BEAKER_IP##*.}"
    log_info "[DEBUG] IP last octet: ${IP_LAST_OCTET}"
  else
    log_error "BEAKER_IP not found in environment variable, Vault secret, or ${SHARED_DIR}/beaker_ip"
    exit 1
  fi
else
  log_info "Using BEAKER_IP from environment variable: ${BEAKER_IP}"
  # DEBUG: Print last octet of IP address for verification
  IP_LAST_OCTET="${BEAKER_IP##*.}"
  log_info "[DEBUG] IP last octet: ${IP_LAST_OCTET}"
fi

# Beaker machine user
# Priority: environment variable > Vault secret > default (root)
if [ -z "${BEAKER_USER:-}" ]; then
  if [ -f "/var/run/beaker-bm/beaker-user" ]; then
    BEAKER_USER=$(cat "/var/run/beaker-bm/beaker-user")
    log_info "Read Beaker user from Vault secret: ${BEAKER_USER}"
  else
    BEAKER_USER="root"
    log_info "Using default Beaker user: ${BEAKER_USER}"
  fi
else
  log_info "Using BEAKER_USER from environment variable: ${BEAKER_USER}"
fi

# Kind cluster name
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
log_info "Kind cluster name: ${KIND_CLUSTER_NAME}"

# Container runtime (docker or podman) - default: docker (must match ref.yaml)
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
log_info "Container runtime: ${CONTAINER_RUNTIME}"

# ============================================================================
# SSH Key Setup
# ============================================================================

progress "Setting up SSH key"

# Try to read SSH key from Vault-mounted secret first, fallback to CLUSTER_PROFILE_DIR
# Vault path: secrets/kv/selfservice/confidential-qe/beaker-bm
# K8s secret: beaker-bm in test-credentials namespace
# Mount path: /var/run/beaker-bm/beaker-ssh-private-key
SSH_PKEY_PATH_VAULT="/var/run/beaker-bm/beaker-ssh-private-key"

if [ -f "${SSH_PKEY_PATH_VAULT}" ]; then
  SSH_PKEY_PATH="${SSH_PKEY_PATH_VAULT}"
  log_info "Using SSH key from Vault: ${SSH_PKEY_PATH_VAULT}"
elif [ -n "${CLUSTER_PROFILE_DIR:-}" ] && [ -f "${CLUSTER_PROFILE_DIR}/ssh-key" ]; then
  SSH_PKEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-key"
  log_info "Using SSH key from CLUSTER_PROFILE_DIR: ${CLUSTER_PROFILE_DIR}/ssh-key"
else
  log_error "SSH key not found at ${SSH_PKEY_PATH_VAULT}"
  if [ -n "${CLUSTER_PROFILE_DIR:-}" ]; then
    log_error "Also checked: ${CLUSTER_PROFILE_DIR}/ssh-key"
  fi
  exit 1
fi

SSH_PKEY="${HOME}/.ssh/beaker_key"
mkdir -p "${HOME}/.ssh"
cp "${SSH_PKEY_PATH}" "${SSH_PKEY}"
chmod 600 "${SSH_PKEY}"
log_info "SSH private key configured at ${SSH_PKEY}"

# DEBUG: Print detailed key information
log_info "[DEBUG] === SSH Private Key Diagnostics ==="
log_info "[DEBUG] Key file permissions: $(ls -l ${SSH_PKEY} | awk '{print $1}')"
log_info "[DEBUG] Key file size: $(wc -c < ${SSH_PKEY}) bytes"
log_info "[DEBUG] Key first line: $(head -1 ${SSH_PKEY})"
log_info "[DEBUG] Key last 20 chars: $(cat ${SSH_PKEY} | tr -d '\n' | tail -c 20)"
log_info "[DEBUG] Key line count: $(wc -l < ${SSH_PKEY}) lines"

# Verify key format and validity
if head -1 "${SSH_PKEY}" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
  log_info "[DEBUG] Key format: OpenSSH (new format)"
elif head -1 "${SSH_PKEY}" | grep -q "BEGIN RSA PRIVATE KEY"; then
  log_info "[DEBUG] Key format: RSA (traditional format)"
elif head -1 "${SSH_PKEY}" | grep -q "BEGIN.*PRIVATE KEY"; then
  log_info "[DEBUG] Key format: $(head -1 ${SSH_PKEY})"
else
  log_error "[DEBUG] Key format: UNKNOWN or INVALID"
  log_error "[DEBUG] First 100 chars of file: $(head -c 100 ${SSH_PKEY})"
fi

# Try to validate the key with ssh-keygen
log_info "[DEBUG] Validating key with ssh-keygen..."
if ssh-keygen -l -f "${SSH_PKEY}" &>/dev/null; then
  KEY_FINGERPRINT=$(ssh-keygen -l -f "${SSH_PKEY}" 2>/dev/null)
  log_info "[DEBUG] Key is valid. Fingerprint: ${KEY_FINGERPRINT}"
else
  log_warn "[DEBUG] ssh-keygen validation failed - attempting format conversion..."

  # OpenSSH new format may not be compatible with some libcrypto versions
  # Try to convert to traditional PEM format
  if head -1 "${SSH_PKEY}" | grep -q "BEGIN OPENSSH PRIVATE KEY"; then
    log_info "[DEBUG] Detected OpenSSH new format - converting to PEM format..."

    # Create backup
    cp "${SSH_PKEY}" "${SSH_PKEY}.backup"

    # Convert: extract public key, then convert private key to PEM format
    # Use ssh-keygen with -p (change passphrase) and -m PEM to convert format
    if ssh-keygen -p -N "" -m PEM -f "${SSH_PKEY}" &>/dev/null; then
      log_success "[DEBUG] Successfully converted key to PEM format"

      # Verify the converted key
      if ssh-keygen -l -f "${SSH_PKEY}" &>/dev/null; then
        KEY_FINGERPRINT=$(ssh-keygen -l -f "${SSH_PKEY}" 2>/dev/null)
        log_success "[DEBUG] Converted key is valid. Fingerprint: ${KEY_FINGERPRINT}"
        log_info "[DEBUG] New key format: $(head -1 ${SSH_PKEY})"
      else
        log_error "[DEBUG] Converted key is still invalid - restoring backup"
        mv "${SSH_PKEY}.backup" "${SSH_PKEY}"
        log_error "[DEBUG] Key conversion failed - private key may be corrupted"
        CRITICAL_FAILURE=true
        DEPLOYMENT_STATUS=3
        exit 3
      fi
    else
      log_error "[DEBUG] Failed to convert key format"
      log_error "[DEBUG] This may indicate the key is passphrase-protected or corrupted"
      CRITICAL_FAILURE=true
      DEPLOYMENT_STATUS=3
      exit 3
    fi
  else
    log_error "[DEBUG] Key format is not OpenSSH new format, but still invalid"
    log_error "[DEBUG] Private key may be corrupted"
    CRITICAL_FAILURE=true
    DEPLOYMENT_STATUS=3
    exit 3
  fi
fi
log_info "[DEBUG] === End of Key Diagnostics ==="

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
# Pre-flight Connectivity Check
# ============================================================================

progress "Pre-flight connectivity check"

log_info "Testing network connectivity to ${BEAKER_IP}..."
if timeout 5 ping -c 3 "${BEAKER_IP}" &>/dev/null; then
  log_success "Beaker machine ${BEAKER_IP} responds to ping"
else
  log_warn "Beaker machine ${BEAKER_IP} does not respond to ping (may be expected if ICMP is blocked)"
fi

log_info "Testing SSH port accessibility..."

# Try multiple methods to test port 22 connectivity
PORT_REACHABLE=false

# Method 1: Try /dev/tcp (may not work in all containers)
if timeout 5 bash -c "</dev/tcp/${BEAKER_IP}/22" 2>/dev/null; then
  PORT_REACHABLE=true
  log_success "SSH port 22 is accessible on ${BEAKER_IP} (via /dev/tcp)"
# Method 2: Try nc (netcat) if available
elif command -v nc &>/dev/null && timeout 5 nc -zv "${BEAKER_IP}" 22 2>&1 | grep -q succeeded; then
  PORT_REACHABLE=true
  log_success "SSH port 22 is accessible on ${BEAKER_IP} (via nc)"
# Method 3: Try telnet if available
elif command -v telnet &>/dev/null && timeout 5 bash -c "echo | telnet ${BEAKER_IP} 22" 2>&1 | grep -q Connected; then
  PORT_REACHABLE=true
  log_success "SSH port 22 is accessible on ${BEAKER_IP} (via telnet)"
fi

if ! $PORT_REACHABLE; then
  log_warn "SSH port 22 connectivity test failed on ${BEAKER_IP}"
  log_warn "Port accessibility check failed with all available methods"
  log_warn "Will attempt SSH connection anyway - this may indicate:"
  log_warn "  1. Network routing restrictions between Prow CI and Beaker machine"
  log_warn "  2. /dev/tcp not available in container"
  log_warn "  3. Firewall blocking port scanning but allowing SSH"
fi

# ============================================================================
# SSH Key Authentication
# ============================================================================
# Note: SSH public key is pre-configured on Beaker machine
# The private key from Vault will be used for authentication
# No automatic key deployment is needed

log_info "SSH public key is assumed to be pre-configured on Beaker machine"
log_info "Will use private key from Vault for authentication: ${SSH_PKEY}"

# ============================================================================
# SSH Connection Test with Enhanced Retry
# ============================================================================

progress "Establishing SSH connection to Beaker machine"

log_info "Testing SSH connection to ${BEAKER_USER}@${BEAKER_IP}..."

MAX_SSH_ATTEMPTS=15
BASE_RETRY_DELAY=5

for attempt in $(seq 1 $MAX_SSH_ATTEMPTS); do
  RETRY_DELAY=$((BASE_RETRY_DELAY * attempt / 3))
  [ $RETRY_DELAY -gt 30 ] && RETRY_DELAY=30

  # On first attempt, use verbose SSH debugging to diagnose key issues
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
    # Subsequent attempts without verbose output
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
# Log Collection Function
# ============================================================================

collect_deployment_logs() {
  log_info "Collecting deployment logs and artifacts..."

  local collection_failed=false
  mkdir -p "${ARTIFACT_DIR}/beaker-logs"

  # Determine sudo command based on remote user
  local REMOTE_SUDO=""
  if [ "${BEAKER_USER}" != "root" ]; then
    REMOTE_SUDO="sudo"
  fi

  # Collect deployment log
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-deployment-logs/deployment.log" \
    "${ARTIFACT_DIR}/beaker-logs/deployment.log" 2>&1 || {
    log_warn "Failed to collect deployment log"
    collection_failed=true
  }

  # Collect runtime logs
  ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "${REMOTE_SUDO} journalctl -u ${CONTAINER_RUNTIME} --no-pager -n 500" \
    > "${ARTIFACT_DIR}/beaker-logs/${CONTAINER_RUNTIME}.log" 2>&1 || {
    log_warn "Failed to collect runtime logs"
    collection_failed=true
  }

  # Collect Kind cluster info
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-deployment-logs/*.log" \
    "${ARTIFACT_DIR}/beaker-logs/" 2>&1 || {
    log_warn "Failed to collect Kind logs"
    collection_failed=true
  }

  # Collect system info
  ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "uname -a; echo '---'; free -h; echo '---'; df -h; echo '---'; ip addr" \
    > "${ARTIFACT_DIR}/beaker-logs/system-info.log" 2>&1 || {
    log_warn "Failed to collect system info"
    collection_failed=true
  }

  # Collect K8s cluster state
  if [ -f "${SHARED_DIR}/kubeconfig" ]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    kubectl get nodes -o yaml > "${ARTIFACT_DIR}/beaker-logs/k8s-nodes.yaml" 2>&1 || true
    kubectl get pods -A -o yaml > "${ARTIFACT_DIR}/beaker-logs/k8s-pods.yaml" 2>&1 || true
    kubectl version > "${ARTIFACT_DIR}/beaker-logs/k8s-version.log" 2>&1 || true
  fi

  if $collection_failed; then
    return 1
  else
    log_success "All logs collected successfully"
    return 0
  fi
}

# ============================================================================
# Deploy Kind Cluster using cocl-operator Setup
# ============================================================================

progress "Deploying Kind cluster using cocl-operator setup"

log_info "Generating deployment script in CI pod..."

# Generate the deployment script locally in CI pod
cat > /tmp/beaker-setup.sh << 'SETUPSCRIPT'
#!/bin/bash
set -o nounset
set -o pipefail
set -x
# ============================================================================
# Set PATH for non-interactive SSH session
# ============================================================================
# Explicitly set a complete PATH to ensure all system commands are accessible
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Parse arguments with defaults for local testing
KIND_CLUSTER_NAME="${1:-kind}"
CONTAINER_RUNTIME="${2:-docker}"
BEAKER_IP="${3:-127.0.0.1}"
COCL_OPERATOR_REPO="${4:-https://github.com/trusted-execution-clusters/operator.git}"
COCL_OPERATOR_BRANCH="${5:-main}"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Beaker IP: ${BEAKER_IP}"
echo "Runtime: ${CONTAINER_RUNTIME}"
echo "Date: $(date)"
echo "Current PATH: ${PATH}"
echo "=========================================="

# ============================================================================
# COMPLETELY DISABLE FIREWALL - CI Testing Environment
# ============================================================================
echo "[INFO] =========================================="
echo "[INFO] Completely Disabling Firewall for CI Testing"
echo "[INFO] =========================================="

# Determine if sudo is needed
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# Stop and disable firewalld permanently
echo "[INFO] Stopping and disabling firewalld..."
${SUDO} systemctl stop firewalld 2>/dev/null || true
${SUDO} systemctl disable firewalld 2>/dev/null || true
${SUDO} systemctl mask firewalld 2>/dev/null || true
echo "[SUCCESS] firewalld disabled"

# Set iptables default policies to ACCEPT
echo "[INFO] Setting iptables default policies to ACCEPT..."
${SUDO} iptables -P INPUT ACCEPT 2>/dev/null || true
${SUDO} iptables -P FORWARD ACCEPT 2>/dev/null || true
${SUDO} iptables -P OUTPUT ACCEPT 2>/dev/null || true
echo "[SUCCESS] iptables default policies set to ACCEPT"

# Flush all iptables rules (fresh start)
echo "[INFO] Flushing all iptables rules..."
${SUDO} iptables -F 2>/dev/null || true
${SUDO} iptables -X 2>/dev/null || true
${SUDO} iptables -t nat -F 2>/dev/null || true
${SUDO} iptables -t nat -X 2>/dev/null || true
${SUDO} iptables -t mangle -F 2>/dev/null || true
${SUDO} iptables -t mangle -X 2>/dev/null || true
echo "[SUCCESS] All iptables rules flushed"

# Show final iptables status
echo "[INFO] Final iptables configuration:"
${SUDO} iptables -L -n -v 2>/dev/null || true

echo "[SUCCESS] Firewall completely disabled - all traffic allowed"

# ============================================================================
# Create Persistent SSH Protection via systemd Service
# ============================================================================
echo "[INFO] Creating persistent SSH protection systemd service..."

# Create the SSH protection script
cat > /tmp/ssh-protect.sh << 'SSHPROTECT'
#!/bin/bash
# Persistent SSH Protection - ensures port 22 is always accessible
while true; do
    # Ensure firewalld is stopped
    systemctl is-active firewalld >/dev/null 2>&1 && systemctl stop firewalld

    # Ensure default policies are ACCEPT
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true

    sleep 2
done
SSHPROTECT

chmod +x /tmp/ssh-protect.sh

# Create systemd service file
${SUDO} tee /etc/systemd/system/ssh-protect.service > /dev/null << 'SSHSERVICE'
[Unit]
Description=SSH Port Protection Service for CI Testing
After=network.target

[Service]
Type=simple
ExecStart=/tmp/ssh-protect.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SSHSERVICE

# Enable and start the service
${SUDO} systemctl daemon-reload
${SUDO} systemctl enable ssh-protect.service
${SUDO} systemctl start ssh-protect.service

# Verify service is running
sleep 2
if ${SUDO} systemctl is-active ssh-protect.service >/dev/null 2>&1; then
    echo "[SUCCESS] SSH protection service is running"
    ${SUDO} systemctl status ssh-protect.service --no-pager || true
else
    echo "[ERROR] SSH protection service failed to start"
    ${SUDO} journalctl -u ssh-protect.service --no-pager -n 20 || true
fi

echo "=========================================="

# Create log directory
mkdir -p /tmp/kind-deployment-logs
exec > >(tee -a /tmp/kind-deployment-logs/deployment.log)
exec 2>&1

# ============================================================================
# Install Dependencies
# ============================================================================
echo "[INFO] Installing dependencies..."

# Detect package manager
if command -v dnf &> /dev/null; then
  PKG_MGR="dnf"
elif command -v yum &> /dev/null; then
  PKG_MGR="yum"
else
  echo "[ERROR] Neither dnf nor yum package manager found"
  exit 1
fi

# Install basic prerequisites (from patch)
echo "[INFO] Installing basic prerequisites..."
${SUDO} ${PKG_MGR} install -y curl gcc make dnf-plugins-core wget tar git jq

# ============================================================================
# Install Rust via rustup (from patch)
# ============================================================================
echo "[INFO] Installing Rust via rustup (Official Method)..."
if ! command -v rustc &> /dev/null; then
    echo "[INFO] Rust not found. Installing via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
else
    echo "[INFO] Rust is already installed: $(rustc --version)"
    echo "[INFO] Updating rustup and toolchains..."
    # Source the env to ensure rustup is in the PATH for the update command
    source "$HOME/.cargo/env"
    rustup update
fi
# Add Rust to the system-wide PATH for all users
RUST_PROFILE_SCRIPT="/etc/profile.d/rust.sh"
if ! [ -f "${RUST_PROFILE_SCRIPT}" ]; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' | ${SUDO} tee "${RUST_PROFILE_SCRIPT}"
fi
# Source the new profile script to make Rust available in the current session
source "${RUST_PROFILE_SCRIPT}"
rustc --version
cargo --version

echo "[SUCCESS] Rust installed successfully"

# ============================================================================
# Install Docker CE and Podman (from patch)
# ============================================================================
echo "[INFO] Installing Docker CE and Podman..."

# Create Docker CE repo manually (Fedora compatible)
${SUDO} tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<'DOCKERREPO'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
DOCKERREPO

# Install both Docker and Podman to allow the user to choose the runtime
${SUDO} ${PKG_MGR} install -y docker-ce docker-ce-cli containerd.io podman

echo "[SUCCESS] Docker CE and Podman installed"

# ============================================================================
# Install additional dependencies
# ============================================================================
echo "[INFO] Installing additional dependencies (conntrack, golang)..."
${SUDO} ${PKG_MGR} install -y \
  conntrack \
  golang \
  || echo "[WARN] Some packages may already be installed"

echo "[SUCCESS] Additional dependencies installed"

# ============================================================================
# Start Container Runtime Services
# ============================================================================
echo "[INFO] Starting container runtime services..."

# Start Docker service
${SUDO} systemctl enable --now docker
echo "[INFO] Docker service enabled and started"

# Start Podman socket
${SUDO} systemctl enable --now podman.socket
echo "[INFO] Podman socket enabled and started"

# Display versions
docker --version
podman --version

# Verify the selected runtime is working
echo "[INFO] Verifying ${CONTAINER_RUNTIME} is working..."
${SUDO} systemctl status ${CONTAINER_RUNTIME} --no-pager || true
sleep 5

if ! ${SUDO} ${CONTAINER_RUNTIME} version; then
  echo "[ERROR] ${CONTAINER_RUNTIME} is not working properly"
  ${SUDO} journalctl -u ${CONTAINER_RUNTIME} --no-pager -n 50 > /tmp/kind-deployment-logs/${CONTAINER_RUNTIME}-journal.log
  exit 1
fi

echo "[SUCCESS] ${CONTAINER_RUNTIME} is running"

# ============================================================================
# Install kubectl (fixed version from patch)
# ============================================================================
echo "[INFO] Installing kubectl..."

K8S_VERSION="v1.29.0"  # Pinned version from patch
INSTALLED_K8S_VERSION=""
KUBECTL_PATH="/usr/local/bin/kubectl"
if command -v kubectl &> /dev/null; then
    # Extract version, handle potential errors if kubectl is broken
    INSTALLED_K8S_VERSION=$(kubectl version --client -o=json 2>/dev/null | jq -r .clientVersion.gitVersion || echo "unknown")
fi
if [[ "${INSTALLED_K8S_VERSION}" == "${K8S_VERSION}" ]]; then
    echo "[INFO] kubectl is already installed at the desired version (${K8S_VERSION})."
else
    echo "[INFO] Installing kubectl version ${K8S_VERSION}..."
    KUBECTL_URL="https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
    echo "[INFO] Downloading from: ${KUBECTL_URL}"

    if ! curl -Lo ./kubectl "${KUBECTL_URL}"; then
        echo "[ERROR] Failed to download kubectl from ${KUBECTL_URL}"
        exit 1
    fi

    # Verify download is actually a binary (not HTML error page)
    if file ./kubectl | grep -q "ELF.*executable"; then
        echo "[INFO] Download verified: ELF executable"
    else
        echo "[ERROR] Downloaded file is not an ELF executable:"
        file ./kubectl
        head -5 ./kubectl
        exit 1
    fi

    chmod +x kubectl
    ${SUDO} mv kubectl "${KUBECTL_PATH}"
fi

kubectl version --client || {
  echo "[ERROR] kubectl installation failed"
  exit 1
}

echo "[SUCCESS] kubectl installed"

# ============================================================================
# Install Kind (fixed version from patch)
# ============================================================================
echo "[INFO] Installing Kind..."
KIND_VERSION="v0.30.0"  # Pinned version from patch
KIND_PATH="/usr/local/bin/kind"
if [[ "$(kind version -q 2>/dev/null)" == "${KIND_VERSION}" ]]; then
    echo "[INFO] kind is already installed at the desired version (${KIND_VERSION})."
else
    echo "[INFO] Installing kind version ${KIND_VERSION}..."
    # Use GitHub releases URL for more reliability
    KIND_URL="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
    echo "[INFO] Downloading from: ${KIND_URL}"

    if ! curl -Lo ./kind "${KIND_URL}"; then
        echo "[ERROR] Failed to download kind from ${KIND_URL}"
        exit 1
    fi

    # Verify download is actually a binary (not HTML error page)
    if file ./kind | grep -q "ELF.*executable"; then
        echo "[INFO] Download verified: ELF executable"
    else
        echo "[ERROR] Downloaded file is not an ELF executable:"
        file ./kind
        head -5 ./kind
        exit 1
    fi

    chmod +x kind
    ${SUDO} mv kind "${KIND_PATH}"
fi

kind version || {
  echo "[ERROR] Kind installation failed"
  exit 1
}

echo "[SUCCESS] Kind installed"

# ============================================================================
# Install Go (verify installation from earlier step)
# ============================================================================
echo "[INFO] Verifying Go installation..."
go version || {
  echo "[WARN] Go not found, attempting to install..."
  ${SUDO} ${PKG_MGR} install -y golang
}
echo "[SUCCESS] Go is available"

# Configure Go module proxy globally for all users and containers
# This avoids network timeout issues when downloading Go modules

# Method 1: System-wide environment variables (for shell sessions)
GO_PROXY_SCRIPT="/etc/profile.d/go-proxy.sh"
if ! [ -f "${GO_PROXY_SCRIPT}" ]; then
    echo "[INFO] Configuring global Go module proxy in /etc/profile.d..."
    cat <<'GOPROXY_CONFIG' | ${SUDO} tee "${GO_PROXY_SCRIPT}" > /dev/null
# Global Go module proxy configuration
# Use China mirrors for faster download, with fallback to direct
export GOPROXY="https://goproxy.cn,https://goproxy.io,direct"
export GOSUMDB="sum.golang.org"
GOPROXY_CONFIG
    echo "[SUCCESS] Go proxy configured at ${GO_PROXY_SCRIPT}"
else
    echo "[INFO] Go proxy already configured in /etc/profile.d"
fi

# Method 2: Use 'go env -w' to set Go environment persistently
# This writes to the user's go/env file which Go commands automatically read
echo "[INFO] Configuring Go environment with 'go env -w'..."

# Set for current user
go env -w GOPROXY="https://goproxy.cn,https://goproxy.io,direct"
go env -w GOSUMDB="sum.golang.org"
echo "[INFO] Current user Go env configured"

# Set for root user (containers often run as root during build)
${SUDO} sh -c 'go env -w GOPROXY="https://goproxy.cn,https://goproxy.io,direct"'
${SUDO} sh -c 'go env -w GOSUMDB="sum.golang.org"'
echo "[INFO] Root user Go env configured"

# Source the proxy config for current session
source "${GO_PROXY_SCRIPT}"
echo "[INFO] Go environment configured:"
echo "  GOPROXY: ${GOPROXY}"
echo "  Root GOPROXY: $(${SUDO} go env GOPROXY)"
echo "  User GOPROXY: $(go env GOPROXY)"

# ============================================================================
# Install virtualization packages (from patch)
# ============================================================================
echo "[INFO] Installing virtualization packages..."
${SUDO} ${PKG_MGR} install -y libvirt libvirt-daemon-kvm qemu-kvm yq

echo "[SUCCESS] Virtualization packages installed"

# ============================================================================
# Start libvirt services (from patch)
# ============================================================================
echo "[INFO] Starting libvirt services..."

for drv in qemu network storage;
do
    ${SUDO} systemctl start virt${drv}d.socket
    ${SUDO} systemctl start virt${drv}d-ro.socket
done

# List virsh networks for verification
virsh net-list --all || echo "[WARN] virsh network list failed, may require configuration"

echo "[SUCCESS] libvirt services started"

# ============================================================================
# Download cocl-operator Repository
# ============================================================================
echo "[INFO] Downloading cocl-operator repository..."

WORK_DIR="${HOME}/cocl-operator-kind-setup"
rm -rf "${WORK_DIR}"

# Extract repository owner and name from URL
# Example: https://github.com/trusted-execution-clusters/operator.git
REPO_URL_CLEAN="${COCL_OPERATOR_REPO%.git}"  # Remove .git suffix if present
REPO_OWNER=$(echo "${REPO_URL_CLEAN}" | awk -F'/' '{print $(NF-1)}')
REPO_NAME=$(echo "${REPO_URL_CLEAN}" | awk -F'/' '{print $NF}')

echo "[INFO] Repository: ${REPO_OWNER}/${REPO_NAME}"
echo "[INFO] Branch: ${COCL_OPERATOR_BRANCH}"

# Download tarball from GitHub (avoids git authentication issues)
TARBALL_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${COCL_OPERATOR_BRANCH}.tar.gz"
TEMP_TARBALL="/tmp/cocl-operator-${COCL_OPERATOR_BRANCH}.tar.gz"

echo "[INFO] Downloading from: ${TARBALL_URL}"

if ! curl -L -f -o "${TEMP_TARBALL}" "${TARBALL_URL}"; then
  echo "[ERROR] Failed to download cocl-operator repository"
  echo "[ERROR] URL: ${TARBALL_URL}"
  echo "[INFO] Trying with wget as fallback..."

  if ! wget -O "${TEMP_TARBALL}" "${TARBALL_URL}"; then
    echo "[ERROR] Both curl and wget failed to download repository"
    exit 1
  fi
fi

echo "[SUCCESS] Downloaded tarball"
# Extract tarball
echo "[INFO] Extracting tarball..."
tar -xzf "${TEMP_TARBALL}" -C "${HOME}"

# Dynamically detect the extracted directory name
# List all directories containing "operator" in ${HOME}, sorted by modification time (newest first)
# Exclude the target WORK_DIR if it somehow exists
echo "[INFO] Detecting extracted directory..."
EXTRACTED_DIR=$(ls -dt "${HOME}"/*operator* 2>/dev/null | grep -v "cocl-operator-kind-setup" | head -1)

if [ -z "${EXTRACTED_DIR}" ] || [ ! -d "${EXTRACTED_DIR}" ]; then
  echo "[ERROR] Could not find extracted directory"
  echo "[INFO] Listing all directories in ${HOME}:"
  ls -la "${HOME}"
  exit 1
fi

echo "[INFO] Found extracted directory: ${EXTRACTED_DIR}"

# Rename extracted directory to expected name
# Note: WORK_DIR must not exist for mv to rename (not create WORK_DIR as parent)
mv "${EXTRACTED_DIR}" "${WORK_DIR}"
rm -f "${TEMP_TARBALL}"

echo "[INFO] Directory structure after rename:"
ls -la "${WORK_DIR}" | head -10

cd "${WORK_DIR}"
echo "[SUCCESS] Repository downloaded and extracted to ${WORK_DIR}"

# ============================================================================
# Adapt Kind Config for External Access
# ============================================================================
echo "[INFO] Adapting kind configuration for external access..."

# Backup original config
cp kind/config.yaml kind/config.yaml.orig

# Add API server configuration for external access
cat > kind/config.yaml << KINDCONFIG
# Adapted from cocl-operator kind/config.yaml for external access
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "${BEAKER_IP}"
  apiServerPort: 6443
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
  extraPortMappings:
  # Note: 6443 is already handled by apiServerAddress/apiServerPort above
  # Adding it here would cause "address already in use" error
  - containerPort: 31000
    hostPort: 8080
    protocol: TCP
  - containerPort: 31001
    hostPort: 8000
    protocol: TCP
featureGates:
  "ImageVolume": true
KINDCONFIG

echo "[INFO] Adapted kind configuration:"
cat kind/config.yaml

# ============================================================================
# Patch scripts/common.sh to fix DOCKER_HOST for root docker
# ============================================================================
echo "[INFO] Patching scripts/common.sh to fix DOCKER_HOST..."
echo "[INFO] Current directory: $(pwd)"
echo "[INFO] Searching for scripts/common.sh..."
find . -name "common.sh" -type f 2>/dev/null | head -5 || echo "  No common.sh found"

if [ -f "scripts/common.sh" ]; then
  echo "[INFO] Found scripts/common.sh, backing up and rewriting..."

  # Backup original
  cp scripts/common.sh scripts/common.sh.orig

  echo "=========================================="
  echo "[DEBUG] Original scripts/common.sh content:"
  cat -n scripts/common.sh
  echo "=========================================="

  # Don't try to patch with sed - just completely rewrite it
  # This avoids bash syntax errors from empty if blocks
  echo "[INFO] Completely rewriting scripts/common.sh for root docker..."

  cat > scripts/common.sh << 'COMMON_SH_FIXED'
#!/bin/bash
# Patched by CI to fix DOCKER_HOST issue
# Root docker uses /var/run/docker.sock by default, no need to set DOCKER_HOST

RUNTIME=${RUNTIME:-docker}

# For podman, we need to set some environment variables
if [ "$RUNTIME" == "podman" ]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/podman/podman.sock
  fi
fi

# For docker, use defaults (no DOCKER_HOST needed for root docker)
# Docker daemon socket is at /var/run/docker.sock by default
COMMON_SH_FIXED

  echo "=========================================="
  echo "[DEBUG] New scripts/common.sh content:"
  cat -n scripts/common.sh
  echo "=========================================="

  echo "[INFO] Diff between original and new:"
  diff -u scripts/common.sh.orig scripts/common.sh || true

  echo "[SUCCESS] scripts/common.sh rewritten successfully"
else
  echo "[WARN] scripts/common.sh not found in ${WORK_DIR}"
  echo "[INFO] Creating a minimal scripts/common.sh for docker..."
  mkdir -p scripts
  cat > scripts/common.sh << 'COMMON_SH_NEW'
#!/bin/bash
# Created by CI - minimal common.sh for docker
RUNTIME=${RUNTIME:-docker}
echo "[INFO] Runtime set to: ${RUNTIME}"
# For root docker, no special environment variables needed
COMMON_SH_NEW
  chmod +x scripts/common.sh
  echo "[SUCCESS] Created minimal scripts/common.sh"
fi

# Verify the file is syntactically correct
echo "[INFO] Verifying scripts/common.sh syntax..."
if bash -n scripts/common.sh; then
  echo "[SUCCESS] scripts/common.sh has valid bash syntax"
else
  echo "[ERROR] scripts/common.sh has syntax errors!"
  cat -n scripts/common.sh
  exit 1
fi

echo "[SUCCESS] scripts/common.sh is ready for docker"

# ============================================================================
# Patch all scripts to fix podman-specific flags for docker
# ============================================================================
echo "[INFO] Patching scripts to remove podman-specific flags..."

# Find and patch scripts that use --replace flag (podman-only)
for script in scripts/*.sh; do
  if [ -f "${script}" ] && grep -q "\-\-replace" "${script}"; then
    echo "[INFO] Patching ${script} to fix --replace flag..."
    cp "${script}" "${script}.orig"

    # Replace the logic that sets --replace flag for docker
    # Original: if [ $RUNTIME == docker ]; then args=" --replace"; fi
    # Fixed: if [ $RUNTIME == podman ]; then args=" --replace"; fi
    sed -i "s/if \[ \$RUNTIME == docker \]/if [ \$RUNTIME == podman ]/g" "${script}"
    sed -i "s/if \[ \"\$RUNTIME\" == \"docker\" \]/if [ \"\$RUNTIME\" == \"podman\" ]/g" "${script}"

    # Also add docker-specific logic: remove existing container before creating
    # Find lines with "docker run" or "${RUNTIME} run" and add container removal before it
    # We'll do a more comprehensive fix: replace the whole section

    echo "[INFO] ${script} patched"
    echo "[DEBUG] Diff:"
    diff -u "${script}.orig" "${script}" || true
  fi
done

# Specifically fix the registry creation logic in create-cluster-kind.sh
if [ -f "scripts/create-cluster-kind.sh" ]; then
  echo "[INFO] Applying comprehensive fix to scripts/create-cluster-kind.sh..."
  cp scripts/create-cluster-kind.sh scripts/create-cluster-kind.sh.orig2

  # Create a fixed version with proper docker/podman logic
  # Find the registry creation section and fix it
  cat > /tmp/registry-fix.awk << 'AWKFIX'
/reg_name=kind-registry/ {
  in_registry_section = 1
  print
  next
}

in_registry_section && /^\+/ {
  # Skip lines until we find the docker run command
  next
}

in_registry_section && /\$\{RUNTIME\} run/ {
  # Replace the entire registry creation logic
  print "# CI: Fixed for docker compatibility (docker doesn't support --replace)"
  print "if [ \"${RUNTIME}\" == \"podman\" ]; then"
  print "  # Podman supports --replace flag"
  print "  ${RUNTIME} run --replace --network kind -d --restart=always -p \"127.0.0.1:${reg_port}:5000\" --name \"${reg_name}\" registry:2"
  print "else"
  print "  # Docker: remove existing container first, then create new one"
  print "  ${RUNTIME} rm -f \"${reg_name}\" 2>/dev/null || true"
  print "  ${RUNTIME} run --network kind -d --restart=always -p \"127.0.0.1:${reg_port}:5000\" --name \"${reg_name}\" registry:2"
  print "fi"
  in_registry_section = 0
  next
}

{ print }
AWKFIX

  # Actually, let's use a simpler sed approach
  # Replace the problematic section directly
  sed -i '/args=/,/\${RUNTIME} run.*kind-registry/c\
# CI: Fixed for docker compatibility (docker does not support --replace flag)\
if [ "${RUNTIME}" == "podman" ]; then\
  # Podman supports --replace flag\
  ${RUNTIME} run --replace --network kind -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" registry:2\
else\
  # Docker: remove existing container first, then create new one\
  ${RUNTIME} rm -f "${reg_name}" 2>/dev/null || true\
  ${RUNTIME} run --network kind -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" registry:2\
fi' scripts/create-cluster-kind.sh

  echo "[INFO] scripts/create-cluster-kind.sh patched for docker compatibility"
  echo "[DEBUG] Diff:"
  diff -u scripts/create-cluster-kind.sh.orig2 scripts/create-cluster-kind.sh || true
fi

echo "[SUCCESS] All scripts patched for docker compatibility"

# ============================================================================
# Set Runtime Environment
# ============================================================================
export RUNTIME="${CONTAINER_RUNTIME}"
if [ "$RUNTIME" == "podman" ]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock
fi

echo "[SUCCESS] Runtime environment configured: ${RUNTIME}"

# ============================================================================
# Verify Tools Installation
# ============================================================================
echo "[INFO] Verifying installed tools..."

echo "[INFO] Container Runtime: ${RUNTIME}"
${RUNTIME} version || echo "[WARN] ${RUNTIME} version check failed"

echo "[INFO] Docker version:"
docker --version || echo "[WARN] docker version check failed"

echo "[INFO] Podman version:"
podman --version || echo "[WARN] podman version check failed"

echo "[INFO] kubectl version:"
kubectl version --client || echo "[WARN] kubectl version check failed"

echo "[INFO] kind version:"
kind version || echo "[WARN] kind version check failed"

echo "[INFO] git version:"
git --version || echo "[WARN] git version check failed"

echo "[INFO] Rust version:"
rustc --version || echo "[WARN] rustc version check failed"
cargo --version || echo "[WARN] cargo version check failed"

echo "[INFO] Go version:"
go version || echo "[WARN] go version check failed"

echo "[INFO] libvirt status:"
virsh version || echo "[WARN] virsh version check failed"

echo "[SUCCESS] All tools and dependencies installed successfully"
echo "[INFO] cocl-operator repository available at: ${WORK_DIR}"
echo "[INFO] kind configuration available at: ${WORK_DIR}/kind/config.yaml"

SETUPSCRIPT

# Make the script executable
chmod +x /tmp/beaker-setup.sh

log_success "Deployment script generated ($(wc -l < /tmp/beaker-setup.sh) lines)"

# ============================================================================
# Transfer Script to Beaker Machine
# ============================================================================

log_info "Transferring deployment script to Beaker machine..."

if ! scp "${SSHOPTS[@]}" /tmp/beaker-setup.sh "${BEAKER_USER}@${BEAKER_IP}:/tmp/beaker-setup.sh"; then
  log_error "Failed to transfer deployment script to Beaker machine"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=2
  exit 2
fi

log_success "Script transferred successfully to ${BEAKER_USER}@${BEAKER_IP}:/tmp/beaker-setup.sh"

# ============================================================================
# Execute Script on Beaker Machine
# ============================================================================

log_info "Executing deployment script on Beaker machine..."
log_info "Timeout: ${KIND_CREATE_TIMEOUT} seconds"

# Execute with explicit PATH setting and source system profile if available
if ! timeout "${KIND_CREATE_TIMEOUT}" ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
  "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${PATH:-}; \
   [ -f /etc/profile ] && source /etc/profile 2>/dev/null || true; \
   bash /tmp/beaker-setup.sh '${KIND_CLUSTER_NAME}' '${CONTAINER_RUNTIME}' '${BEAKER_IP}' '${COCL_OPERATOR_REPO}' '${COCL_OPERATOR_BRANCH}'"; then
  log_error "Remote deployment script failed or timed out after ${KIND_CREATE_TIMEOUT} seconds"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=2
fi

# Check if deployment failed
if $CRITICAL_FAILURE; then
  log_error "Critical failure during deployment"
  collect_deployment_logs || true
  exit ${DEPLOYMENT_STATUS}
fi

log_success "Environment preparation completed successfully"

# ============================================================================
# Collect Deployment Logs and Artifacts
# ============================================================================

progress "Collecting logs and artifacts"

collect_deployment_logs || log_warn "Log collection encountered errors"

# ============================================================================
# Save Deployment Metadata
# ============================================================================

progress "Saving deployment metadata"

log_info "Saving deployment information to SHARED_DIR..."

cat > "${SHARED_DIR}/beaker_info" << EOFINFO
BEAKER_IP=${BEAKER_IP}
BEAKER_USER=${BEAKER_USER}
KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}
CONTAINER_RUNTIME=${CONTAINER_RUNTIME}
COCL_OPERATOR_REPO=${COCL_OPERATOR_REPO}
COCL_OPERATOR_BRANCH=${COCL_OPERATOR_BRANCH}
DEPLOYMENT_DATE="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOFINFO

log_info "Deployment info saved to ${SHARED_DIR}/beaker_info"

# ============================================================================
# Final Status Check
# ============================================================================

if $CRITICAL_FAILURE; then
  echo ""
  echo "=========================================="
  echo "Beaker Environment Preparation - FAILED"
  echo "=========================================="
  echo "Exit code: ${DEPLOYMENT_STATUS}"
  echo "Check logs in ${ARTIFACT_DIR}/beaker-logs/"
  echo "=========================================="
  exit ${DEPLOYMENT_STATUS}
fi

echo ""
echo "=========================================="
echo "Beaker Environment Preparation - Completed Successfully"
echo "=========================================="
echo "Beaker Machine: ${BEAKER_IP}"
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo ""
echo "Installed Tools:"
echo "  - Docker CE (container runtime)"
echo "  - Podman (container runtime)"
echo "  - kubectl v1.29.0 (Kubernetes CLI)"
echo "  - kind v0.30.0 (Kubernetes in Docker)"
echo "  - git (version control)"
echo "  - Rust (rustc + cargo)"
echo "  - Go (golang)"
echo "  - libvirt + qemu-kvm (virtualization)"
echo "  - make, gcc, jq, yq (build tools)"
echo ""
echo "cocl-operator repository:"
echo "  Repository: ${COCL_OPERATOR_REPO}"
echo "  Branch: ${COCL_OPERATOR_BRANCH}"
echo "  Location: \${HOME}/cocl-operator-kind-setup"
echo ""
echo "kind configuration ready at:"
echo "  \${HOME}/cocl-operator-kind-setup/kind/config.yaml"
echo ""
echo "To create a kind cluster manually:"
echo "  ssh ${BEAKER_USER}@${BEAKER_IP}"
echo "  cd \${HOME}/cocl-operator-kind-setup"
echo "  kind create cluster --name ${KIND_CLUSTER_NAME} --config kind/config.yaml"
echo "=========================================="
date
