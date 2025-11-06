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
COCL_OPERATOR_REPO="${COCL_OPERATOR_REPO:-https://github.com/confidential-clusters/cocl-operator.git}"
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
  elif [ -f "${SHARED_DIR}/beaker_ip" ]; then
    BEAKER_IP=$(cat "${SHARED_DIR}/beaker_ip")
    log_info "Read Beaker IP from SHARED_DIR: ${BEAKER_IP}"
  else
    log_error "BEAKER_IP not found in environment variable, Vault secret, or ${SHARED_DIR}/beaker_ip"
    exit 1
  fi
else
  log_info "Using BEAKER_IP from environment variable: ${BEAKER_IP}"
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

# ============================================================================
# SSH Options Configuration
# ============================================================================

progress "Configuring SSH connection"

SSHOPTS=(
  -o 'ConnectTimeout=10'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=30'
  -o 'ServerAliveCountMax=5'
  -o 'LogLevel=ERROR'
  -i "${SSH_PKEY}"
)

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

  if ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "echo 'SSH test successful'; hostname; uptime"; then
    log_success "SSH connection established after ${attempt} attempt(s)"
    break
  else
    if [[ $attempt -eq $MAX_SSH_ATTEMPTS ]]; then
      log_error "Failed to establish SSH connection after ${MAX_SSH_ATTEMPTS} attempts"
      CRITICAL_FAILURE=true
      DEPLOYMENT_STATUS=1
      exit 1
    fi
    log_warn "SSH connection failed, attempt ${attempt}/${MAX_SSH_ATTEMPTS}. Retrying in ${RETRY_DELAY} seconds..."
    sleep $RETRY_DELAY
  fi
done

# ============================================================================
# Log Collection Function
# ============================================================================

collect_deployment_logs() {
  log_info "Collecting deployment logs and artifacts..."

  local collection_failed=false
  mkdir -p "${ARTIFACT_DIR}/beaker-logs"

  # Collect deployment log
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-deployment-logs/deployment.log" \
    "${ARTIFACT_DIR}/beaker-logs/deployment.log" 2>&1 || {
    log_warn "Failed to collect deployment log"
    collection_failed=true
  }

  # Collect runtime logs
  ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "sudo journalctl -u ${CONTAINER_RUNTIME} --no-pager -n 500" \
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

log_info "Executing deployment script on Beaker machine..."

if ! timeout "${KIND_CREATE_TIMEOUT}" ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${KIND_CLUSTER_NAME}" "${CONTAINER_RUNTIME}" "${BEAKER_IP}" \
  "${COCL_OPERATOR_REPO}" "${COCL_OPERATOR_BRANCH}" << 'EOF'

set -o nounset
set -o pipefail
set -x

KIND_CLUSTER_NAME="$1"
CONTAINER_RUNTIME="$2"
BEAKER_IP="$3"
COCL_OPERATOR_REPO="$4"
COCL_OPERATOR_BRANCH="$5"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Beaker IP: ${BEAKER_IP}"
echo "Runtime: ${CONTAINER_RUNTIME}"
echo "Date: $(date)"
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

# Install required packages
echo "[INFO] Installing ${CONTAINER_RUNTIME}, git, and other dependencies..."
sudo ${PKG_MGR} install -y \
  ${CONTAINER_RUNTIME} \
  git \
  curl \
  wget \
  jq \
  conntrack \
  make \
  golang \
  || echo "[WARN] Some packages may already be installed"

# ============================================================================
# Start Container Runtime
# ============================================================================
echo "[INFO] Starting ${CONTAINER_RUNTIME} service..."
sudo systemctl enable ${CONTAINER_RUNTIME}
sudo systemctl start ${CONTAINER_RUNTIME}
sudo systemctl status ${CONTAINER_RUNTIME} --no-pager || true
sleep 5

# Verify runtime is working
if ! sudo ${CONTAINER_RUNTIME} version; then
  echo "[ERROR] ${CONTAINER_RUNTIME} is not working properly"
  sudo journalctl -u ${CONTAINER_RUNTIME} --no-pager -n 50 > /tmp/kind-deployment-logs/${CONTAINER_RUNTIME}-journal.log
  exit 1
fi

echo "[SUCCESS] ${CONTAINER_RUNTIME} is running"

# ============================================================================
# Install kubectl
# ============================================================================
echo "[INFO] Installing kubectl..."

KUBECTL_PATH="/usr/local/bin/kubectl"
if [ ! -f "${KUBECTL_PATH}" ]; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl "${KUBECTL_PATH}"
  rm kubectl
else
  echo "[INFO] kubectl already installed"
fi

kubectl version --client || {
  echo "[ERROR] kubectl installation failed"
  exit 1
}

echo "[SUCCESS] kubectl installed"

# ============================================================================
# Install Kind
# ============================================================================
echo "[INFO] Installing Kind..."

KIND_PATH="/usr/local/bin/kind"
if [ ! -f "${KIND_PATH}" ]; then
  curl -Lo ./kind "https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64"
  sudo install -o root -g root -m 0755 kind "${KIND_PATH}"
  rm kind
else
  echo "[INFO] Kind already installed"
fi

kind version || {
  echo "[ERROR] Kind installation failed"
  exit 1
}

echo "[SUCCESS] Kind installed"

# ============================================================================
# Download cocl-operator Repository
# ============================================================================
echo "[INFO] Downloading cocl-operator repository..."

WORK_DIR="${HOME}/cocl-operator-kind-setup"
rm -rf "${WORK_DIR}"

# Extract repository owner and name from URL
# Example: https://github.com/confidential-clusters/cocl-operator.git
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

# The extracted directory will be named repo-branch (e.g., cocl-operator-main)
EXTRACTED_DIR="${HOME}/${REPO_NAME}-${COCL_OPERATOR_BRANCH}"

if [ ! -d "${EXTRACTED_DIR}" ]; then
  echo "[ERROR] Extracted directory not found: ${EXTRACTED_DIR}"
  ls -la "${HOME}" | grep cocl
  exit 1
fi

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

echo "[INFO] kubectl version:"
kubectl version --client || echo "[WARN] kubectl version check failed"

echo "[INFO] kind version:"
kind version || echo "[WARN] kind version check failed"

echo "[INFO] git version:"
git --version || echo "[WARN] git version check failed"

echo "[SUCCESS] All tools and dependencies installed successfully"
echo "[INFO] cocl-operator repository available at: ${WORK_DIR}"
echo "[INFO] kind configuration available at: ${WORK_DIR}/kind/config.yaml"

EOF
then
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
DEPLOYMENT_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
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
echo "  - ${CONTAINER_RUNTIME} (container runtime)"
echo "  - kubectl (Kubernetes CLI)"
echo "  - kind (Kubernetes in Docker)"
echo "  - git"
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
