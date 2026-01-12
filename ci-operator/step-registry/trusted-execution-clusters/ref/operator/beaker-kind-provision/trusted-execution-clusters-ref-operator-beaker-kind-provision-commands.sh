#!/bin/bash

set -o nounset
set -o pipefail

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
date

# Prow CI User Environment Setup
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
fi

# Global Variables
DEPLOYMENT_STATUS=0
CRITICAL_FAILURE=false

SETUP_SCRIPT_TIMEOUT="${SETUP_SCRIPT_TIMEOUT:-900}"

OPERATOR_REPO="${OPERATOR_REPO:-https://github.com/trusted-execution-clusters/operator.git}"
OPERATOR_BRANCH="${OPERATOR_BRANCH:-main}"

TOTAL_STEPS=8
CURRENT_STEP=0

# Helper Functions
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

# Environment Variables Check
progress "Checking environment variables"

if [ -z "${BEAKER_IP:-}" ]; then
  if [ -f "/var/run/beaker-bm/beaker-ip" ]; then
    BEAKER_IP=$(cat "/var/run/beaker-bm/beaker-ip")
    log_info "Read Beaker IP from Vault secret: ${BEAKER_IP}"
  elif [ -f "${SHARED_DIR}/beaker_ip" ]; then
    BEAKER_IP=$(cat "${SHARED_DIR}/beaker_ip")
    log_info "Read Beaker IP from SHARED_DIR: ${BEAKER_IP}"
  else
    log_error "BEAKER_IP not found"
    exit 1
  fi
else
  log_info "Using BEAKER_IP from environment variable: ${BEAKER_IP}"
fi

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

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
log_info "Kind cluster name: ${KIND_CLUSTER_NAME}"

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
log_info "Container runtime: ${CONTAINER_RUNTIME}"

# SSH Key Setup
progress "Setting up SSH key"

SSH_PKEY_PATH_VAULT="/var/run/beaker-bm/beaker-ssh-private-key"

if [ -f "${SSH_PKEY_PATH_VAULT}" ]; then
  SSH_PKEY_PATH="${SSH_PKEY_PATH_VAULT}"
  log_info "Using SSH key from Vault: ${SSH_PKEY_PATH_VAULT}"
elif [ -n "${CLUSTER_PROFILE_DIR:-}" ] && [ -f "${CLUSTER_PROFILE_DIR}/ssh-key" ]; then
  SSH_PKEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-key"
  log_info "Using SSH key from CLUSTER_PROFILE_DIR: ${CLUSTER_PROFILE_DIR}/ssh-key"
else
  log_error "SSH key not found"
  exit 1
fi

SSH_PKEY="${HOME}/.ssh/beaker_key"
mkdir -p "${HOME}/.ssh"
cp "${SSH_PKEY_PATH}" "${SSH_PKEY}"
chmod 600 "${SSH_PKEY}"
log_info "SSH private key configured at ${SSH_PKEY}"

# SSH Options Configuration
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

log_info "SSH connection timeout set to 120 seconds"

# Pre-flight Connectivity Check
progress "Pre-flight connectivity check"

log_info "Testing network connectivity to ${BEAKER_IP}..."
if timeout 5 ping -c 3 "${BEAKER_IP}" &>/dev/null; then
  log_success "Beaker machine ${BEAKER_IP} responds to ping"
else
  log_warn "Beaker machine ${BEAKER_IP} does not respond to ping (may be expected if ICMP is blocked)"
fi

# SSH Connection Test with Retry
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

# Log Collection Function
collect_deployment_logs() {
  log_info "Collecting deployment logs and artifacts..."

  local collection_failed=false
  mkdir -p "${ARTIFACT_DIR}/beaker-logs"

  local REMOTE_SUDO=""
  if [ "${BEAKER_USER}" != "root" ]; then
    REMOTE_SUDO="sudo"
  fi

  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-deployment-logs/deployment.log" \
    "${ARTIFACT_DIR}/beaker-logs/deployment.log" 2>&1 || {
    log_warn "Failed to collect deployment log"
    collection_failed=true
  }

  ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "${REMOTE_SUDO} journalctl -u ${CONTAINER_RUNTIME} --no-pager -n 500" \
    > "${ARTIFACT_DIR}/beaker-logs/${CONTAINER_RUNTIME}.log" 2>&1 || {
    log_warn "Failed to collect runtime logs"
    collection_failed=true
  }

  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-deployment-logs/*.log" \
    "${ARTIFACT_DIR}/beaker-logs/" 2>&1 || {
    log_warn "Failed to collect Kind logs"
    collection_failed=true
  }

  ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "uname -a; echo '---'; free -h; echo '---'; df -h; echo '---'; ip addr" \
    > "${ARTIFACT_DIR}/beaker-logs/system-info.log" 2>&1 || {
    log_warn "Failed to collect system info"
    collection_failed=true
  }

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

# Prepare Beaker Environment with Dependencies and operator Repository
progress "Preparing Beaker environment"

log_info "Generating environment setup script..."

cat > /tmp/beaker-setup.sh << 'SETUPSCRIPT'
#!/bin/bash
set -o nounset
set -o pipefail
set -x

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

KIND_CLUSTER_NAME="${1:-kind}"
CONTAINER_RUNTIME="${2:-docker}"
BEAKER_IP="${3:-127.0.0.1}"
OPERATOR_REPO="${4:-https://github.com/trusted-execution-clusters/operator.git}"
OPERATOR_BRANCH="${5:-main}"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Beaker IP: ${BEAKER_IP}"
echo "Runtime: ${CONTAINER_RUNTIME}"
echo "Date: $(date)"
echo "=========================================="

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

mkdir -p /tmp/kind-deployment-logs
exec > >(tee -a /tmp/kind-deployment-logs/deployment.log)
exec 2>&1

# Install Dependencies
echo "[INFO] Installing dependencies..."

if command -v dnf &> /dev/null; then
  PKG_MGR="dnf"
elif command -v yum &> /dev/null; then
  PKG_MGR="yum"
else
  echo "[ERROR] Neither dnf nor yum package manager found"
  exit 1
fi

echo "[INFO] Installing basic prerequisites..."
${SUDO} ${PKG_MGR} install -y curl gcc make dnf-plugins-core wget tar git jq

# Install Rust
echo "[INFO] Installing Rust via rustup..."
if ! command -v rustc &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
else
    echo "[INFO] Rust is already installed: $(rustc --version)"
    source "$HOME/.cargo/env"
    rustup update
fi

RUST_PROFILE_SCRIPT="/etc/profile.d/rust.sh"
if ! [ -f "${RUST_PROFILE_SCRIPT}" ]; then
    echo 'export PATH="$HOME/.cargo/bin:$PATH"' | ${SUDO} tee "${RUST_PROFILE_SCRIPT}"
fi
source "${RUST_PROFILE_SCRIPT}"
rustc --version
cargo --version

echo "[SUCCESS] Rust installed successfully"

# Install Docker CE
echo "[INFO] Installing Docker CE..."

${SUDO} tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<'DOCKERREPO'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
DOCKERREPO

${SUDO} ${PKG_MGR} install -y docker-ce docker-ce-cli containerd.io

echo "[SUCCESS] Docker CE installed"

echo "[INFO] Installing additional dependencies..."
${SUDO} ${PKG_MGR} install -y conntrack golang || echo "[WARN] Some packages may already be installed"

echo "[SUCCESS] Additional dependencies installed"

# Start Container Runtime Service
echo "[INFO] Starting Docker service..."

${SUDO} systemctl enable --now docker
echo "[INFO] Docker service enabled and started"

docker --version

echo "[INFO] Verifying ${CONTAINER_RUNTIME} is working..."
${SUDO} systemctl status ${CONTAINER_RUNTIME} --no-pager || true
sleep 5

if ! ${SUDO} ${CONTAINER_RUNTIME} version; then
  echo "[ERROR] ${CONTAINER_RUNTIME} is not working properly"
  JOURNAL_LOG="/tmp/kind-deployment-logs/${CONTAINER_RUNTIME}-journal.log"
  ${SUDO} journalctl -u ${CONTAINER_RUNTIME} --no-pager -n 50 > "${JOURNAL_LOG}"
  exit 1
fi

echo "[SUCCESS] ${CONTAINER_RUNTIME} is running"

# Ensure containerd directories exist and have correct permissions
echo "[INFO] Ensuring containerd directories exist..."
${SUDO} mkdir -p /var/lib/containerd/io.containerd.content.v1.content/ingest
${SUDO} mkdir -p /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots
${SUDO} mkdir -p /var/lib/containerd/tmpmounts
${SUDO} chmod -R 755 /var/lib/containerd

echo "[INFO] Restarting Docker to ensure containerd is properly initialized..."
${SUDO} systemctl restart docker
sleep 10

echo "[INFO] Verifying Docker and containerd after restart..."
if ! ${SUDO} docker info > /dev/null 2>&1; then
  echo "[ERROR] Docker is not responding after restart"
  ${SUDO} journalctl -u docker --no-pager -n 100 > /tmp/kind-deployment-logs/docker-restart-journal.log
  exit 1
fi

echo "[SUCCESS] Docker and containerd are properly initialized"

# Install kubectl
echo "[INFO] Installing kubectl..."

K8S_VERSION="v1.29.0"
INSTALLED_K8S_VERSION=""
KUBECTL_PATH="/usr/local/bin/kubectl"
if command -v kubectl &> /dev/null; then
    INSTALLED_K8S_VERSION=$(kubectl version --client -o=json 2>/dev/null | \
        jq -r .clientVersion.gitVersion || echo "unknown")
fi
if [[ "${INSTALLED_K8S_VERSION}" == "${K8S_VERSION}" ]]; then
    echo "[INFO] kubectl is already installed at the desired version (${K8S_VERSION})."
else
    echo "[INFO] Installing kubectl version ${K8S_VERSION}..."
    KUBECTL_URL="https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"

    if ! curl -Lo ./kubectl "${KUBECTL_URL}"; then
        echo "[ERROR] Failed to download kubectl from ${KUBECTL_URL}"
        exit 1
    fi

    if file ./kubectl | grep -q "ELF.*executable"; then
        echo "[INFO] Download verified: ELF executable"
    else
        echo "[ERROR] Downloaded file is not an ELF executable"
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

# Install Kind
echo "[INFO] Installing Kind..."
KIND_VERSION="v0.30.0"
KIND_PATH="/usr/local/bin/kind"
if [[ "$(kind version -q 2>/dev/null)" == "${KIND_VERSION}" ]]; then
    echo "[INFO] kind is already installed at the desired version (${KIND_VERSION})."
else
    echo "[INFO] Installing kind version ${KIND_VERSION}..."
    KIND_URL="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"

    if ! curl -Lo ./kind "${KIND_URL}"; then
        echo "[ERROR] Failed to download kind from ${KIND_URL}"
        exit 1
    fi

    if file ./kind | grep -q "ELF.*executable"; then
        echo "[INFO] Download verified: ELF executable"
    else
        echo "[ERROR] Downloaded file is not an ELF executable"
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

# Install Go
echo "[INFO] Installing Go 1.25.0 or higher..."

GO_VERSION="1.25.0"
GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"
GO_INSTALL_DIR="/usr/local"
GO_DOWNLOAD_URL="https://go.dev/dl/${GO_TARBALL}"

# Check if Go is already installed and meets version requirement
CURRENT_GO_VERSION=""
if command -v go &> /dev/null; then
    CURRENT_GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
    echo "[INFO] Current Go version: ${CURRENT_GO_VERSION}"

    # Compare versions (simple comparison, assumes format X.Y.Z)
    CURRENT_MAJOR=$(echo "${CURRENT_GO_VERSION}" | cut -d. -f1)
    CURRENT_MINOR=$(echo "${CURRENT_GO_VERSION}" | cut -d. -f2)
    REQUIRED_MAJOR=$(echo "${GO_VERSION}" | cut -d. -f1)
    REQUIRED_MINOR=$(echo "${GO_VERSION}" | cut -d. -f2)

    if [ "${CURRENT_MAJOR}" -gt "${REQUIRED_MAJOR}" ] || \
       { [ "${CURRENT_MAJOR}" -eq "${REQUIRED_MAJOR}" ] && [ "${CURRENT_MINOR}" -ge "${REQUIRED_MINOR}" ]; }; then
        echo "[INFO] Go version ${CURRENT_GO_VERSION} meets requirement (>= ${GO_VERSION})"
    else
        echo "[WARN] Go version ${CURRENT_GO_VERSION} is lower than required ${GO_VERSION}, upgrading..."
        NEED_UPGRADE=true
    fi
else
    echo "[INFO] Go not found, installing version ${GO_VERSION}..."
    NEED_UPGRADE=true
fi

if [ "${NEED_UPGRADE:-false}" = "true" ]; then
    echo "[INFO] Downloading Go ${GO_VERSION} from ${GO_DOWNLOAD_URL}..."

    if ! curl -L -f -o "/tmp/${GO_TARBALL}" "${GO_DOWNLOAD_URL}"; then
        echo "[ERROR] Failed to download Go from ${GO_DOWNLOAD_URL}"
        exit 1
    fi

    echo "[INFO] Extracting Go to ${GO_INSTALL_DIR}..."
    ${SUDO} rm -rf "${GO_INSTALL_DIR}/go"
    ${SUDO} tar -C "${GO_INSTALL_DIR}" -xzf "/tmp/${GO_TARBALL}"
    rm -f "/tmp/${GO_TARBALL}"

    echo "[INFO] Setting up Go environment..."
    export PATH="${GO_INSTALL_DIR}/go/bin:${PATH}"

    # Ensure Go is in PATH for all users
    GO_PROFILE_SCRIPT="/etc/profile.d/go.sh"
    if ! [ -f "${GO_PROFILE_SCRIPT}" ]; then
        echo "export PATH=\"${GO_INSTALL_DIR}/go/bin:\${PATH}\"" | ${SUDO} tee "${GO_PROFILE_SCRIPT}"
    fi
fi

# Verify installation
if ! go version; then
    echo "[ERROR] Go installation verification failed"
    exit 1
fi

echo "[SUCCESS] Go installed: $(go version)"

# Configure Go module proxy
echo "[INFO] Configuring Go module proxy..."
GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
GOSUMDB="${GOSUMDB:-sum.golang.org}"

go env -w GOPROXY="${GOPROXY}"
go env -w GOSUMDB="${GOSUMDB}"

echo "[SUCCESS] Go proxy configured: ${GOPROXY}"

# Download operator Repository
echo "[INFO] Downloading operator repository..."

WORK_DIR="${HOME}/operator-kind-setup"
rm -rf "${WORK_DIR}"

REPO_URL_CLEAN="${OPERATOR_REPO%.git}"
REPO_OWNER=$(echo "${REPO_URL_CLEAN}" | awk -F'/' '{print $(NF-1)}')
REPO_NAME=$(echo "${REPO_URL_CLEAN}" | awk -F'/' '{print $NF}')

echo "[INFO] Repository: ${REPO_OWNER}/${REPO_NAME}"
echo "[INFO] Branch: ${OPERATOR_BRANCH}"

TARBALL_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${OPERATOR_BRANCH}.tar.gz"
TEMP_TARBALL="/tmp/operator-${OPERATOR_BRANCH}.tar.gz"

echo "[INFO] Downloading from: ${TARBALL_URL}"

if ! curl -L -f -o "${TEMP_TARBALL}" "${TARBALL_URL}"; then
  echo "[INFO] Trying with wget as fallback..."
  if ! wget -O "${TEMP_TARBALL}" "${TARBALL_URL}"; then
    echo "[ERROR] Both curl and wget failed to download repository"
    exit 1
  fi
fi

echo "[SUCCESS] Downloaded tarball"

echo "[INFO] Extracting tarball..."
tar -xzf "${TEMP_TARBALL}" -C "${HOME}"

EXTRACTED_DIR=$(ls -dt "${HOME}"/*operator* 2>/dev/null | grep -v "operator-kind-setup" | head -1)

if [ -z "${EXTRACTED_DIR}" ] || [ ! -d "${EXTRACTED_DIR}" ]; then
  echo "[ERROR] Could not find extracted directory"
  exit 1
fi

mv "${EXTRACTED_DIR}" "${WORK_DIR}"
rm -f "${TEMP_TARBALL}"

cd "${WORK_DIR}"
echo "[SUCCESS] Repository downloaded and extracted to ${WORK_DIR}"

# Apply patch from PR #113
echo "[INFO] Applying patch from PR #113..."
PATCH_URL_113="https://github.com/trusted-execution-clusters/operator/pull/113.patch"
if curl -L -f -o /tmp/pr-113.patch "${PATCH_URL_113}"; then
  if git apply /tmp/pr-113.patch; then
    echo "[SUCCESS] PR #113 patch applied successfully"
  else
    echo "[WARN] Failed to apply patch with git apply, trying patch command..."
    if patch -p1 < /tmp/pr-113.patch; then
      echo "[SUCCESS] PR #113 patch applied successfully with patch command"
    else
      echo "[ERROR] Failed to apply PR #113 patch"
      exit 1
    fi
  fi
  rm -f /tmp/pr-113.patch
else
  echo "[ERROR] Failed to download patch from ${PATCH_URL_113}"
  exit 1
fi

# Apply patch from PR #119
echo "[INFO] Applying patch from PR #119..."
PATCH_URL_119="https://github.com/trusted-execution-clusters/operator/pull/119.patch"
if curl -L -f -o /tmp/pr-119.patch "${PATCH_URL_119}"; then
  if git apply /tmp/pr-119.patch; then
    echo "[SUCCESS] PR #119 patch applied successfully"
  else
    echo "[WARN] Failed to apply patch with git apply, trying patch command..."
    if patch -p1 < /tmp/pr-119.patch; then
      echo "[SUCCESS] PR #119 patch applied successfully with patch command"
    else
      echo "[ERROR] Failed to apply PR #119 patch"
      exit 1
    fi
  fi
  rm -f /tmp/pr-119.patch
else
  echo "[ERROR] Failed to download patch from ${PATCH_URL_119}"
  exit 1
fi

# Adapt Kind Config for External Access
echo "[INFO] Adapting kind configuration for external access..."

cp kind/config.yaml kind/config.yaml.orig

cat > kind/config.yaml << KINDCONFIG
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
  - containerPort: 31000
    hostPort: 8080
    protocol: TCP
  - containerPort: 31001
    hostPort: 8000
    protocol: TCP
featureGates:
  "ImageVolume": true
KINDCONFIG

echo "[SUCCESS] Kind configuration adapted for external access"

# Set Runtime Environment
export RUNTIME="${CONTAINER_RUNTIME}"
echo "[SUCCESS] Runtime environment configured: ${RUNTIME}"

# Verify Tools Installation
echo "[INFO] Verifying installed tools..."
${RUNTIME} version
kubectl version --client
kind version
git --version
rustc --version
go version

echo "[SUCCESS] All tools and dependencies installed successfully"

SETUPSCRIPT

chmod +x /tmp/beaker-setup.sh

log_success "Deployment script generated ($(wc -l < /tmp/beaker-setup.sh) lines)"

# Transfer Script to Beaker Machine
log_info "Transferring deployment script to Beaker machine..."

if ! scp "${SSHOPTS[@]}" /tmp/beaker-setup.sh "${BEAKER_USER}@${BEAKER_IP}:/tmp/beaker-setup.sh"; then
  log_error "Failed to transfer deployment script to Beaker machine"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=2
  exit 2
fi

log_success "Script transferred successfully"

# Execute Script on Beaker Machine
log_info "Executing environment setup script on Beaker machine..."
log_info "Timeout: ${SETUP_SCRIPT_TIMEOUT} seconds"

SETUP_CMD="export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${PATH:-};"
SETUP_CMD+=" [ -f /etc/profile ] && source /etc/profile 2>/dev/null || true;"
SETUP_CMD+=" bash /tmp/beaker-setup.sh"
SETUP_CMD+=" '${KIND_CLUSTER_NAME}' '${CONTAINER_RUNTIME}' '${BEAKER_IP}'"
SETUP_CMD+=" '${OPERATOR_REPO}' '${OPERATOR_BRANCH}'"

if ! timeout "${SETUP_SCRIPT_TIMEOUT}" ssh "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}" "${SETUP_CMD}"; then
  log_error "Remote deployment script failed or timed out"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=2
fi

if $CRITICAL_FAILURE; then
  log_error "Critical failure during deployment"
  collect_deployment_logs || true
  exit ${DEPLOYMENT_STATUS}
fi

log_success "Environment preparation completed successfully"

# Collect Deployment Logs and Artifacts
progress "Collecting logs and artifacts"

collect_deployment_logs || log_warn "Log collection encountered errors"

# Save Deployment Metadata
progress "Saving deployment metadata"

cat > "${SHARED_DIR}/beaker_info" << EOFINFO
BEAKER_IP=${BEAKER_IP}
BEAKER_USER=${BEAKER_USER}
KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}
CONTAINER_RUNTIME=${CONTAINER_RUNTIME}
OPERATOR_REPO=${OPERATOR_REPO}
OPERATOR_BRANCH=${OPERATOR_BRANCH}
DEPLOYMENT_DATE="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
EOFINFO

log_info "Deployment info saved to ${SHARED_DIR}/beaker_info"

# Final Status Check
if $CRITICAL_FAILURE; then
  echo ""
  echo "=========================================="
  echo "Beaker Environment Preparation - FAILED"
  echo "=========================================="
  echo "Exit code: ${DEPLOYMENT_STATUS}"
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
echo "  - Docker CE"
echo "  - kubectl v1.29.0"
echo "  - kind v0.30.0"
echo "  - git, Rust, Go"
echo ""
echo "Operator repository:"
echo "  Repository: ${OPERATOR_REPO}"
echo "  Branch: ${OPERATOR_BRANCH}"
echo "=========================================="
date
