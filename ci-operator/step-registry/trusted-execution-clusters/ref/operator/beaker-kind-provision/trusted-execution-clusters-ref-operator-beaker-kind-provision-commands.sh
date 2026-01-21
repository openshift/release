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
      exit 1
    fi
    log_warn "SSH connection failed, attempt ${attempt}/${MAX_SSH_ATTEMPTS}. Retrying in ${RETRY_DELAY} seconds..."
    sleep $RETRY_DELAY
  fi
done

# ============================================================================
# CRITICAL: Acquire Exclusive Lock on Beaker Machine
# ============================================================================
# This prevents multiple CI jobs from running simultaneously on the same
# Beaker machine, which would cause conflicts and test failures.
#
# Lock strategy:
# - Uses flock-based file locking similar to baremetal-lab approach
# - Lock acquired within a persistent script that runs in background
# - Lock held for entire test duration
# - Released by cleanup script in post phase
#
# Lock details:
# - Lock file: /tmp/tec-operator-ci.lock on Beaker machine
# - File descriptor: 200
# - Acquisition timeout: 21600 seconds (6 hours)
# - Hold timeout: 10800 seconds (3 hours safety auto-release)
# - Behavior: If lock cannot be acquired within 6 hours, job fails
# ============================================================================

progress "Acquiring exclusive lock on Beaker machine"

LOCK_FILE="/tmp/tec-operator-ci.lock"
LOCK_TIMEOUT=21600  # 6 hours in seconds (job runtime ~2h, this allows multiple jobs to queue)

# Generate unique lock holder ID for this job
LOCK_HOLDER_ID="${NAMESPACE:-unknown}-${BUILD_ID:-unknown}-$(date +%s)"

log_info "Lock file: ${LOCK_FILE}"
log_info "Lock holder ID: ${LOCK_HOLDER_ID}"
log_info "Lock timeout: ${LOCK_TIMEOUT} seconds (6 hours)"
log_info "This ensures only one CI job runs on the Beaker machine at a time"

# Create lock acquisition and holding script
# This script will:
# 1. Acquire the lock using flock
# 2. Create a marker file with job info
# 3. Hold the lock by sleeping until signaled
# 4. Release when cleanup script sends signal or timeout occurs
cat > /tmp/hold_lock.sh << 'HOLDLOCKSCRIPT'
#!/bin/bash
set -o nounset
set -o pipefail

LOCK_FILE="$1"
LOCK_TIMEOUT="$2"
LOCK_HOLDER_ID="$3"
LOCK_FD=200

echo "[INFO] Lock acquisition starting..."
echo "[INFO] Lock file: ${LOCK_FILE}"
echo "[INFO] Lock holder: ${LOCK_HOLDER_ID}"
echo "[INFO] Lock FD: ${LOCK_FD}"
echo "[INFO] Timeout: ${LOCK_TIMEOUT} seconds (6 hours)"

# Cleanup on exit
cleanup_on_exit() {
  echo "[INFO] Releasing lock (script exiting)..."

  # Release the flock
  flock -u $LOCK_FD 2>/dev/null || true
  eval "exec ${LOCK_FD}>&-" 2>/dev/null || true

  # IMPORTANT: Do NOT delete .holder and .pid files here!
  # These files are needed by:
  # 1. The cleanup script to verify lock release
  # 2. The next job to verify it acquired the lock
  # The cleanup script will handle deletion of these files properly

  echo "[INFO] Lock released (flock)"
}
trap cleanup_on_exit EXIT INT TERM

# Open file descriptor for the lock file
touch "${LOCK_FILE}"
eval "exec ${LOCK_FD}<>\"${LOCK_FILE}\""

# Try to acquire the lock with timeout
echo "[INFO] Waiting for lock (max ${LOCK_TIMEOUT} seconds)..."
echo "[INFO] If another CI job is running, this job will wait in queue..."

START_TIME=$(date +%s)

if flock -w "${LOCK_TIMEOUT}" $LOCK_FD; then
  WAIT_TIME=$(($(date +%s) - START_TIME))
  echo "[SUCCESS] Lock acquired after ${WAIT_TIME} seconds"
  echo "[INFO] This CI job now has exclusive access to the Beaker machine"

  # Create marker file with job information
  # Use atomic write: write to temp file, then rename
  cat > "${LOCK_FILE}.holder.tmp" << HOLDERINFO
LOCK_HOLDER_ID=${LOCK_HOLDER_ID}
LOCK_ACQUIRED_AT=$(date -u +'%Y-%m-%d_%H:%M:%S_UTC')
LOCK_PID=$$
HOLDERINFO

  # Atomic rename to ensure file is complete when it appears
  mv "${LOCK_FILE}.holder.tmp" "${LOCK_FILE}.holder"

  # Save our PID for cleanup script (atomic write)
  echo "$$" > "${LOCK_FILE}.pid.tmp"
  mv "${LOCK_FILE}.pid.tmp" "${LOCK_FILE}.pid"

  echo "[INFO] Lock holder info saved"
  echo "[INFO] Lock is now active and will be held until cleanup"

  # Hold the lock by waiting for signal from cleanup script
  # Also add a safety timeout to auto-release after 3 hours
  HOLD_TIMEOUT=10800  # 3 hours safety timeout (job runtime ~2h + buffer)

  echo "[INFO] Holding lock for up to ${HOLD_TIMEOUT} seconds (3 hour safety limit)..."
  echo "[INFO] Lock will be explicitly released by cleanup script"

  # Wait for either:
  # 1. SIGUSR1 signal from cleanup script (normal release)
  # 2. Timeout after 3 hours (safety release)
  sleep ${HOLD_TIMEOUT} &
  SLEEP_PID=$!

  # Set up signal handler for cleanup script
  trap "kill ${SLEEP_PID} 2>/dev/null; echo '[INFO] Received release signal from cleanup script'; exit 0" USR1

  # Wait for either signal or timeout
  wait ${SLEEP_PID} 2>/dev/null

  echo "[WARN] Lock holding timeout reached (3 hours) - auto-releasing"
  exit 0

else
  echo "[ERROR] Failed to acquire lock after ${LOCK_TIMEOUT} seconds"
  echo "[ERROR] The Beaker machine is still busy with another CI job"
  echo "[ERROR] "
  echo "[ERROR] Current lock holder (if exists):"
  cat "${LOCK_FILE}.holder" 2>/dev/null || echo "[ERROR] No lock holder info found"
  echo "[ERROR] "
  echo "[ERROR] This usually means:"
  echo "[ERROR]   - Another PR's test is still running"
  echo "[ERROR]   - A previous test failed to release the lock (stale lock)"
  echo "[ERROR] "
  echo "[ERROR] Recommended actions:"
  echo "[ERROR]   1. Wait a few minutes and /retest"
  echo "[ERROR]   2. Check if other PRs have running tests"
  echo "[ERROR]   3. If lock is stale (holder PID not running), manually remove:"
  echo "[ERROR]      ssh to Beaker machine and: rm -f ${LOCK_FILE}*"
  exit 1
fi
HOLDLOCKSCRIPT

chmod +x /tmp/hold_lock.sh

# Transfer the lock script to Beaker machine
log_info "Transferring lock holder script to Beaker machine..."
if ! scp "${SSHOPTS[@]}" /tmp/hold_lock.sh "${BEAKER_USER}@${BEAKER_IP}:/tmp/hold_lock.sh"; then
  log_error "Failed to transfer lock script to Beaker machine"
  exit 3
fi

# Start the lock holding process in background on Beaker machine
# This process will keep running and holding the lock until cleanup
log_info "Starting lock holder process on Beaker machine..."
log_info "Acquiring lock (timeout: ${LOCK_TIMEOUT}s / 6 hours)..."

# Use unique log file for this job to avoid conflicts
LOCK_HOLDER_LOG="/tmp/lock-holder-${LOCK_HOLDER_ID}.log"

# Run the lock holder in background, save output to unique log file
if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
  "nohup bash /tmp/hold_lock.sh '${LOCK_FILE}' '${LOCK_TIMEOUT}' '${LOCK_HOLDER_ID}' > '${LOCK_HOLDER_LOG}' 2>&1 &"; then
  log_error "Failed to start lock holder process"
  exit 3
fi

# Wait for lock holder process to either acquire the lock or fail
log_info "Waiting for lock holder process to acquire lock or timeout..."
log_info "This may take up to ${LOCK_TIMEOUT} seconds if another job is running..."

# Poll the lock holder log to see if our job acquired the lock
MAX_POLL_TIME=$((LOCK_TIMEOUT + 30))  # Add 30s buffer for startup
POLL_INTERVAL=5
ELAPSED=0

while [ ${ELAPSED} -lt ${MAX_POLL_TIME} ]; do
  # Check if our specific lock holder ID appears in the holder file
  CURRENT_HOLDER=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "grep 'LOCK_HOLDER_ID' '${LOCK_FILE}.holder' 2>/dev/null | cut -d= -f2" || echo "")

  if [ "${CURRENT_HOLDER}" = "${LOCK_HOLDER_ID}" ]; then
    # Our job acquired the lock!
    log_success "Lock acquired successfully by this job!"
    break
  fi

  # Check if the lock holder process exited (failed to acquire)
  LOCK_HOLDER_LOG_TAIL=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "tail -5 '${LOCK_HOLDER_LOG}' 2>/dev/null" || echo "")

  if echo "${LOCK_HOLDER_LOG_TAIL}" | grep -q "Failed to acquire lock"; then
    log_error "Lock acquisition failed - timeout exceeded"
    log_error "Lock holder log shows:"
    ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "cat '${LOCK_HOLDER_LOG}'" || true
    exit 3
  fi

  # Still waiting, sleep and check again
  if [ $((ELAPSED % 30)) -eq 0 ]; then
    if [ "${CURRENT_HOLDER}" != "" ]; then
      log_info "Still waiting for lock... (currently held by: ${CURRENT_HOLDER})"
    else
      log_info "Still waiting for lock... (${ELAPSED}s elapsed)"
    fi
  fi

  sleep ${POLL_INTERVAL}
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Verify lock was actually acquired by this job
FINAL_HOLDER=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
  "grep 'LOCK_HOLDER_ID' '${LOCK_FILE}.holder' 2>/dev/null | cut -d= -f2" || echo "")

if [ "${FINAL_HOLDER}" != "${LOCK_HOLDER_ID}" ]; then
  log_error "Lock verification failed after ${ELAPSED}s"
  log_error "Expected holder: ${LOCK_HOLDER_ID}"
  log_error "Actual holder: ${FINAL_HOLDER}"
  log_error ""
  log_error "Lock holder log:"
  ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "cat '${LOCK_HOLDER_LOG}'" || true
  exit 3
fi

# Read lock holder info now that we've confirmed it's ours
LOCK_HOLDER_INFO=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "cat '${LOCK_FILE}.holder'")
LOCK_HOLDER_PID=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "cat '${LOCK_FILE}.pid'")

log_success "Lock acquired and verified!"
log_info "Lock holder PID: ${LOCK_HOLDER_PID}"
log_info "Lock holder details:"
echo "${LOCK_HOLDER_INFO}" | while read line; do log_info "  $line"; done

# Save lock information to SHARED_DIR for the cleanup script
LOCK_ACQUIRED_AT_VALUE="$(date -u +'%Y-%m-%d_%H:%M:%S_UTC')"
cat > "${SHARED_DIR}/beaker_lock_info" << LOCKINFO
LOCK_FILE=${LOCK_FILE}
LOCK_HOLDER_ID=${LOCK_HOLDER_ID}
LOCK_HOLDER_PID=${LOCK_HOLDER_PID}
LOCK_HOLDER_LOG=${LOCK_HOLDER_LOG}
LOCK_ACQUIRED=true
LOCK_ACQUIRED_AT=${LOCK_ACQUIRED_AT_VALUE}
LOCKINFO

log_info "Lock information saved to ${SHARED_DIR}/beaker_lock_info"
log_info "This job now has exclusive access to the Beaker machine"

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
${SUDO} ${PKG_MGR} install -y curl gcc make dnf-plugins-core wget tar git jq file

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

if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
    echo "[INFO] Docker is already installed and running: ${DOCKER_VERSION}"
    echo "[INFO] Skipping Docker installation"
else
    echo "[INFO] Docker not found or not running, installing..."

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
fi

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

# Clone operator Repository
echo "[INFO] Cloning operator repository..."

WORK_DIR="${HOME}/operator-kind-setup"
rm -rf "${WORK_DIR}"

echo "[INFO] Repository: ${OPERATOR_REPO}"
echo "[INFO] Branch: ${OPERATOR_BRANCH}"

if ! git clone --depth 1 --branch "${OPERATOR_BRANCH}" "${OPERATOR_REPO}" "${WORK_DIR}"; then
  echo "[ERROR] Failed to clone repository from ${OPERATOR_REPO}"
  exit 1
fi

cd "${WORK_DIR}"

CURRENT_COMMIT=$(git rev-parse HEAD)
CURRENT_COMMIT_SHORT=$(git rev-parse --short HEAD)

echo "[SUCCESS] Repository cloned to ${WORK_DIR}"
echo "[INFO] Current commit: ${CURRENT_COMMIT_SHORT} (${CURRENT_COMMIT})"
echo "[INFO] Commit message: $(git log -1 --pretty=%B | head -1)"

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
