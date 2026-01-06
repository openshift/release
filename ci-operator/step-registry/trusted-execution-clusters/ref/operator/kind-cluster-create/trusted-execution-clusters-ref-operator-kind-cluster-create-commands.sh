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
echo "Kind Cluster Creation - Starting"
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

CLUSTER_CREATE_TIMEOUT="${CLUSTER_CREATE_TIMEOUT:-900}"

TOTAL_STEPS=7
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
log_info "Kind cluster name: ${KIND_CLUSTER_NAME}"
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

# Create Kind Cluster on Beaker Machine
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

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if command -v sudo &> /dev/null; then
    SUDO="sudo"
  else
    SUDO=""
  fi
fi

mkdir -p /tmp/kind-cluster-logs
exec > >(tee -a /tmp/kind-cluster-logs/cluster-creation.log)
exec 2>&1

WORK_DIR="${HOME}/operator-kind-setup"
if [ ! -d "${WORK_DIR}" ]; then
  echo "[ERROR] Operator directory not found: ${WORK_DIR}"
  exit 1
fi

cd "${WORK_DIR}"

if [ -f "/etc/profile.d/go.sh" ]; then
    source "/etc/profile.d/go.sh"
fi
if [ -f "/etc/profile.d/rust.sh" ]; then
    source "/etc/profile.d/rust.sh"
fi

export IP="192.168.122.1"
export RUNTIME="${CONTAINER_RUNTIME}"

echo "[INFO] Environment configured:"
echo "  IP=${IP}"
echo "  RUNTIME=${RUNTIME}"

echo "[INFO] Executing: make cluster-up RUNTIME=${RUNTIME}"
if ! make cluster-up RUNTIME="${RUNTIME}"; then
  echo "[ERROR] 'make cluster-up' failed"
  exit 1
fi

echo "[SUCCESS] Kind cluster created successfully"

echo "[INFO] Verifying cluster access..."
export KUBECONFIG="${HOME}/.kube/config"

if ! kubectl cluster-info; then
  echo "[ERROR] Cannot access cluster"
  exit 1
fi

echo "[INFO] Checking node status..."
kubectl get nodes -o wide

echo "[SUCCESS] Cluster is ready and accessible"

EOF
then
  log_error "Cluster creation failed or timed out"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=1
fi

if $CRITICAL_FAILURE; then
  log_error "Critical failure during cluster creation"

  mkdir -p "${ARTIFACT_DIR}/kind-cluster-logs"
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-cluster-logs/*.log" \
    "${ARTIFACT_DIR}/kind-cluster-logs/" 2>&1 || log_warn "Failed to collect cluster creation logs"

  exit ${DEPLOYMENT_STATUS}
fi

log_success "Kind cluster created successfully on Beaker machine"

# Retrieve Kubeconfig from Beaker Machine
progress "Retrieving kubeconfig from Beaker machine"

log_info "Copying kubeconfig from ${BEAKER_USER}@${BEAKER_IP}..."

if ! scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:.kube/config" \
  "${SHARED_DIR}/kubeconfig"; then
  log_error "Failed to retrieve kubeconfig from Beaker machine"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=1
  exit ${DEPLOYMENT_STATUS}
fi

log_success "Kubeconfig saved to ${SHARED_DIR}/kubeconfig"

log_info "Note: Cluster is only accessible from the Beaker machine, not from CI pod"
log_info "The kubeconfig is saved for use by subsequent steps running on Beaker machine"

# Collect Cluster Logs
progress "Collecting cluster creation logs"

mkdir -p "${ARTIFACT_DIR}/kind-cluster-logs"

scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-cluster-logs/*.log" \
  "${ARTIFACT_DIR}/kind-cluster-logs/" 2>&1 || log_warn "Failed to collect some logs"

log_success "Logs collected to ${ARTIFACT_DIR}/kind-cluster-logs/"
log_info "Cluster resources will be collected by subsequent steps running on Beaker machine"

# Final Status
echo ""
echo "=========================================="
echo "Kind Cluster Creation - Completed Successfully"
echo "=========================================="
echo "Cluster Name: ${KIND_CLUSTER_NAME}"
echo "Beaker Machine: ${BEAKER_IP}"
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo ""
echo "Kubeconfig: ${SHARED_DIR}/kubeconfig"
echo "=========================================="
date
