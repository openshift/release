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
echo "Operator Integration Tests - Starting"
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

POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-900}"

OPERATOR_REPO="${OPERATOR_REPO:-https://github.com/trusted-execution-clusters/operator.git}"
OPERATOR_BRANCH="${OPERATOR_BRANCH:-main}"

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-}"

TOTAL_STEPS=6
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

# Read Configuration from Previous Step
progress "Reading configuration from previous step"

if [ ! -f "${SHARED_DIR}/beaker_info" ]; then
  log_error "beaker_info not found. The beaker-kind-provision step must run first."
  exit 1
fi

source "${SHARED_DIR}/beaker_info"

log_info "Beaker machine: ${BEAKER_IP}"
log_info "Beaker user: ${BEAKER_USER}"
log_info "Container runtime: ${CONTAINER_RUNTIME}"
log_info "Operator repository: ${OPERATOR_REPO}"
log_info "Operator branch: ${OPERATOR_BRANCH}"

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

# Install Operator on Beaker Machine
progress "Running operator integration tests on Beaker machine"

log_info "Executing operator integration tests on Beaker machine..."

if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${CONTAINER_RUNTIME}" "${POD_READY_TIMEOUT}" << 'EOF'

set -euo pipefail
set -x

CONTAINER_RUNTIME="$1"
POD_READY_TIMEOUT="$2"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

mkdir -p /tmp/operator-install-logs
exec > >(tee -a /tmp/operator-install-logs/installation.log)
exec 2>&1

if [ -f "/etc/profile.d/go.sh" ]; then
    source "/etc/profile.d/go.sh"
fi
if [ -f "/etc/profile.d/rust.sh" ]; then
    source "/etc/profile.d/rust.sh"
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# Use operator Repository from Provision Step
echo "[INFO] Using operator repository from provision step..."

WORK_DIR="${HOME}/operator-kind-setup"

if [ ! -d "${WORK_DIR}" ]; then
  echo "[ERROR] Operator repository not found at ${WORK_DIR}"
  echo "[ERROR] The beaker-kind-provision step must run first and download the repository"
  exit 1
fi

cd "${WORK_DIR}"
echo "[SUCCESS] Using operator repository at ${WORK_DIR}"

# Verify Local Registry
echo "[INFO] Verifying local registry is accessible..."

REG_PORT="5000"
if curl -s http://localhost:${REG_PORT}/v2/_catalog >/dev/null 2>&1; then
  echo "[SUCCESS] Registry is accessible at localhost:${REG_PORT}"
else
  echo "[ERROR] Registry is not accessible at localhost:${REG_PORT}"
  exit 1
fi

# Deploy Operator and Run Integration Tests
export RUNTIME="${CONTAINER_RUNTIME}"
export CONTAINER_CLI="${CONTAINER_RUNTIME}"
export REGISTRY=localhost:5000/trusted-execution-clusters

export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.org}"

echo "[INFO] Environment configured:"
echo "  CONTAINER_CLI=${CONTAINER_CLI}"
echo "  RUNTIME=${RUNTIME}"
echo "  REGISTRY=${REGISTRY}"

echo "[INFO] Verifying Kind cluster is running..."
if ! kubectl cluster-info; then
  echo "[ERROR] Kind cluster is not accessible"
  echo "[INFO] Attempting to create cluster..."
  if ! make cluster-up; then
    echo "[ERROR] 'make cluster-up' failed"
    exit 1
  fi
fi

echo "[SUCCESS] Kind cluster is ready"

echo "[INFO] Building and pushing container images to ${REGISTRY}..."
if ! make push; then
  echo "[ERROR] 'make push' failed"
  exit 1
fi

echo "[SUCCESS] Images built and pushed"

echo "[INFO] Installing KubeVirt..."
if ! make install-kubevirt; then
  echo "[ERROR] 'make install-kubevirt' failed"
  exit 1
fi

echo "[SUCCESS] KubeVirt installed"

echo "[INFO] Installing additional dependencies for Rust build..."
if ! sudo dnf install -y gcc-c++ openssl-devel pkg-config; then
  echo "[ERROR] Failed to install build dependencies"
  exit 1
fi

echo "[SUCCESS] Build dependencies installed"

echo "[INFO] Generating CRDs for Rust..."
if ! make crds-rs; then
  echo "[ERROR] 'make crds-rs' failed"
  exit 1
fi

echo "[SUCCESS] Rust CRDs generated"

echo "[INFO] Setting up SSH agent for integration tests..."

# Kill ALL existing ssh-agent processes to prevent accumulation
echo "[INFO] Cleaning up any existing ssh-agent processes..."
${SUDO} pkill -u $(whoami) ssh-agent 2>/dev/null || echo "[INFO] No existing ssh-agent processes found"

# Wait a moment for processes to terminate
sleep 1

# Start fresh ssh-agent
echo "[INFO] Starting new ssh-agent..."
eval "$(ssh-agent -s)"

# Verify ssh-agent is running
if [ -n "${SSH_AGENT_PID:-}" ] && kill -0 "${SSH_AGENT_PID}" 2>/dev/null; then
  echo "[SUCCESS] SSH agent started (PID: ${SSH_AGENT_PID})"
  echo "[INFO] SSH_AUTH_SOCK: ${SSH_AUTH_SOCK}"
else
  echo "[ERROR] Failed to start ssh-agent"
  exit 1
fi

echo "[INFO] Running integration tests..."
if ! make integration-tests; then
  echo "[ERROR] Integration tests failed"
  exit 1
fi

echo "[SUCCESS] Integration tests completed successfully"

echo "[INFO] Collecting test results and cluster state..."
kubectl get all -A > /tmp/operator-install-logs/cluster-all-resources.yaml 2>&1 || true
kubectl get nodes -o wide > /tmp/operator-install-logs/nodes.yaml 2>&1 || true

echo "[SUCCESS] Operator integration tests completed"

EOF
then
  log_error "Operator integration tests failed"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=1
fi

if $CRITICAL_FAILURE; then
  log_error "Critical failure during operator integration tests"

  mkdir -p "${ARTIFACT_DIR}/operator-test-logs"
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-install-logs/*" \
    "${ARTIFACT_DIR}/operator-test-logs/" 2>&1 || log_warn "Failed to collect test logs"

  exit ${DEPLOYMENT_STATUS}
fi

log_success "Operator integration tests completed successfully"

# Collect Test Results and Logs
progress "Collecting test results and logs"

mkdir -p "${ARTIFACT_DIR}/operator-test-logs"

scp "${SSHOPTS[@]}" -r \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-install-logs/*" \
  "${ARTIFACT_DIR}/operator-test-logs/" 2>&1 || log_warn "Failed to collect some test logs"

log_success "Test results collected to ${ARTIFACT_DIR}/operator-test-logs/"

# Final Status
echo ""
echo "=========================================="
echo "Operator Integration Tests - Completed Successfully"
echo "=========================================="
echo "Operator Repository: ${OPERATOR_REPO}"
echo "Operator Branch: ${OPERATOR_BRANCH}"
echo "Beaker Machine: ${BEAKER_IP}"
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo ""
echo "Integration tests passed:"
echo "  - cluster-up: Kind cluster created"
echo "  - push: Container images built and pushed"
echo "  - install-kubevirt: KubeVirt installed"
echo "  - integration-tests: All tests passed"
echo ""
echo "Test results: ${ARTIFACT_DIR}/operator-test-logs/"
echo "=========================================="
date
