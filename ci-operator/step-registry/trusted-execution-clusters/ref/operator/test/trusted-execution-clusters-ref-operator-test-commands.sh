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

# Transfer PR Source Code to Beaker Machine
progress "Transferring PR code to Beaker machine"

# Determine if this is a real operator PR or a rehearsal
# In rehearsals, PULL_NUMBER is set but refers to the release repo PR, not operator PR
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"

log_info "Job context: REPO_OWNER=${REPO_OWNER}, REPO_NAME=${REPO_NAME}, PULL_NUMBER=${PULL_NUMBER:-unset}"

# Check if this is a presubmit for the actual operator repo
if [ -n "${PULL_NUMBER:-}" ] && [ "${REPO_OWNER}" = "trusted-execution-clusters" ] && [ "${REPO_NAME}" = "operator" ]; then
  # This is a real operator PR - transfer PR code from test pod to Beaker
  log_info "Detected operator repo presubmit - PR #${PULL_NUMBER}"
  log_info "Transferring PR code from test pod to Beaker machine"

  # In OpenShift CI, the PR code is already checked out in the test pod
  # Standard location: /go/src/github.com/<org>/<repo>
  PR_CODE_PATH="/go/src/github.com/${REPO_OWNER}/${REPO_NAME}"

  log_info "PR code location in test pod: ${PR_CODE_PATH}"

  if [ ! -d "${PR_CODE_PATH}" ]; then
    log_error "PR code not found at ${PR_CODE_PATH}"
    log_info "Checking current directory as fallback..."
    if [ -f "Makefile" ] && [ -f "Cargo.toml" ]; then
      PR_CODE_PATH="$(pwd)"
      log_info "Found operator code in current directory: ${PR_CODE_PATH}"
    else
      log_error "Could not locate operator repository code in test pod"
      exit 1
    fi
  fi

  # Create tarball of PR code
  log_info "Creating tarball of PR code..."
  PR_TARBALL="/tmp/operator-pr-code.tar.gz"
  if ! tar -czf "${PR_TARBALL}" -C "$(dirname ${PR_CODE_PATH})" "$(basename ${PR_CODE_PATH})"; then
    log_error "Failed to create tarball of PR code"
    exit 1
  fi

  TARBALL_SIZE=$(du -h "${PR_TARBALL}" | cut -f1)
  log_success "Tarball created: ${PR_TARBALL} (${TARBALL_SIZE})"

  # Transfer tarball to Beaker machine
  log_info "Transferring tarball to Beaker machine..."
  if ! scp "${SSHOPTS[@]}" "${PR_TARBALL}" "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-pr-code.tar.gz"; then
    log_error "Failed to transfer PR code tarball to Beaker machine"
    exit 1
  fi

  log_success "Tarball transferred successfully"

  # Cleanup tarball from test pod
  rm -f "${PR_TARBALL}"
  log_info "Cleaned up tarball from test pod"

  # Extract on Beaker machine to separate directory
  log_info "Extracting PR code on Beaker machine..."

  EXTRACT_OUTPUT=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s << 'EXTRACT_EOF'
set -euo pipefail

# Separate directories:
# - ~/operator-kind-setup: Infrastructure (cluster, customized kind/config.yaml) - from provision step
# - ~/operator-pr-code: PR code to test - extracted from test pod
PR_CODE_DIR="${HOME}/operator-pr-code"

echo "[INFO] Extracting PR code to ${PR_CODE_DIR}"

# Remove old directory if exists
rm -rf "${PR_CODE_DIR}"

# Extract tarball
if ! tar -xzf /tmp/operator-pr-code.tar.gz -C "${HOME}"; then
  echo "[ERROR] Failed to extract tarball"
  exit 1
fi

# Rename extracted directory to operator-pr-code (in case it has a different name)
EXTRACTED_DIR=$(tar -tzf /tmp/operator-pr-code.tar.gz | head -1 | cut -d/ -f1)
if [ "${EXTRACTED_DIR}" != "operator-pr-code" ] && [ -d "${HOME}/${EXTRACTED_DIR}" ]; then
  mv "${HOME}/${EXTRACTED_DIR}" "${PR_CODE_DIR}"
fi

# Verify extraction
if [ ! -d "${PR_CODE_DIR}" ]; then
  echo "[ERROR] PR code directory not found after extraction"
  exit 1
fi

cd "${PR_CODE_DIR}"

echo "[SUCCESS] PR code extracted successfully"
echo ""
echo "[INFO] PR code directory: ${PR_CODE_DIR}"
echo "[INFO] Repository structure:"
[ -f "Makefile" ] && echo "  ✓ Makefile" || echo "  ✗ Makefile missing"
[ -f "Cargo.toml" ] && echo "  ✓ Cargo.toml" || echo "  ✗ Cargo.toml missing"
[ -d "src" ] && echo "  ✓ src/" || echo "  ✗ src/ missing"
echo ""

# Show git info if available
if [ -d ".git" ]; then
  echo "[INFO] Git information:"
  git log -1 --pretty=format:"  Commit: %h - %s%n  Author: %an%n  Date: %ad%n" --date=short 2>/dev/null || echo "  (git info unavailable)"
  echo ""
fi

# Cleanup tarball after successful extraction
echo "[INFO] Cleaning up tarball..."
rm -f /tmp/operator-pr-code.tar.gz

echo "=========================================="
echo "PR Code Ready for Testing"
echo "=========================================="
echo "Infrastructure: ~/operator-kind-setup (cluster, config)"
echo "Test code: ~/operator-pr-code (PR code)"
echo "=========================================="

exit 0
EXTRACT_EOF
  )

  EXTRACT_STATUS=$?
  echo "${EXTRACT_OUTPUT}"

  if [ ${EXTRACT_STATUS} -eq 0 ]; then
    log_success "PR code ready on Beaker machine at ~/operator-pr-code"
    TEST_DIR="operator-pr-code"
  else
    log_error "Failed to extract PR code on Beaker machine"
    exit 1
  fi
else
  # Not an operator PR - this is a rehearsal, periodic, or postsubmit
  if [ -n "${PULL_NUMBER:-}" ]; then
    log_info "PULL_NUMBER is set to ${PULL_NUMBER}, but REPO is ${REPO_OWNER}/${REPO_NAME}"
    log_info "This is a rehearsal (testing release repo PR against operator main branch)"
  else
    log_info "PULL_NUMBER not set - periodic or postsubmit job"
  fi

  log_info "Will use existing code on Beaker machine (main branch from provision step)"
  log_info "Skipping PR checkout - proceeding with main branch testing"

  # Show what code will be tested
  CURRENT_CODE=$(ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" \
    "cd ~/operator-kind-setup && git log -1 --pretty=format:'%h - %s (%an, %ad)' --date=short 2>/dev/null || echo 'Git info unavailable'")

  log_info "=========================================="
  log_info "CODE TO BE TESTED (main branch):"
  log_info "  ${CURRENT_CODE}"
  log_info "=========================================="

  TEST_DIR="operator-kind-setup"
fi  # End of operator PR check

# Install Operator on Beaker Machine
progress "Running operator integration tests on Beaker machine"

log_info "Executing operator integration tests on Beaker machine..."
log_info "Test directory: ${TEST_DIR}"

if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${CONTAINER_RUNTIME}" "${POD_READY_TIMEOUT}" "${TEST_DIR}" << 'EOF'

set -euo pipefail
set -x

CONTAINER_RUNTIME="$1"
POD_READY_TIMEOUT="$2"
TEST_DIR="$3"

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

# Use Test Directory (either operator-pr-code for PRs or operator-kind-setup for main)
WORK_DIR="${HOME}/${TEST_DIR}"

echo "[INFO] Using test code from: ${WORK_DIR}"

if [ ! -d "${WORK_DIR}" ]; then
  echo "[ERROR] Test directory not found at ${WORK_DIR}"
  exit 1
fi

cd "${WORK_DIR}"

echo "[SUCCESS] Using operator code at ${WORK_DIR}"
echo "[INFO] Working directory contents:"
ls -la | head -15

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

echo "[INFO] Installing virtctl CLI..."
KUBEVIRT_VERSION=$(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o jsonpath="{.status.observedKubeVirtVersion}" 2>/dev/null || echo "v1.1.1")
echo "[INFO] Detected KubeVirt version: ${KUBEVIRT_VERSION}"

VIRTCTL_URL="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
if ! curl -L -o /tmp/virtctl "${VIRTCTL_URL}"; then
  echo "[ERROR] Failed to download virtctl from ${VIRTCTL_URL}"
  exit 1
fi

chmod +x /tmp/virtctl
${SUDO} mv /tmp/virtctl /usr/local/bin/virtctl

if virtctl version --client; then
  echo "[SUCCESS] virtctl installed successfully"
else
  echo "[ERROR] virtctl installation verification failed"
  exit 1
fi

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

# Kill all existing ssh-agents to ensure clean state (important for CI)
# This prevents inheriting broken agents from previous failed jobs
echo "[INFO] Cleaning up any existing ssh-agent processes..."
${SUDO} pkill -u $(whoami) ssh-agent 2>/dev/null || echo "[INFO] No existing ssh-agent processes found"

# Wait for processes to terminate
sleep 1

# Start fresh ssh-agent
echo "[INFO] Starting new ssh-agent..."
eval "$(ssh-agent -s)"

# Verify ssh-agent started successfully
if [ -z "${SSH_AGENT_PID:-}" ]; then
  echo "[ERROR] Failed to start ssh-agent (SSH_AGENT_PID not set)"
  exit 1
fi

echo "[SUCCESS] SSH agent started (PID: ${SSH_AGENT_PID})"

# Add default SSH keys to agent
echo "[INFO] Adding SSH keys to agent..."
if ssh-add </dev/null 2>&1; then
  echo "[SUCCESS] SSH keys added successfully"
  echo "[INFO] Loaded keys:"
  ssh-add -l 2>&1 | head -3 | sed 's/^/  /'
else
  # ssh-add might fail if no default keys exist, which is OK
  # The agent will still work for SSH connections using key files directly
  echo "[WARN] ssh-add had no default keys to add (this may be expected)"
fi

# Final verification
echo "[INFO] SSH_AUTH_SOCK: ${SSH_AUTH_SOCK}"
echo "[INFO] SSH agent ready for integration tests"

echo "[INFO] Pre-loading test images to Kind node (non-critical optimization step)..."
# IMPORTANT: This entire section is non-critical and must not fail the test
# Load the images using 'docker exec kind-control-plane crictl pull <IMAGE>' as a workaround,
# since loading image and using them as image volumes doesn't work. See https://github.com/kubernetes-sigs/kind/issues/4099

# Extract test images from Makefile
TEST_IMAGE=""
APPROVED_IMAGE=""

if [ -f "Makefile" ]; then
  TEST_IMAGE=$(grep -oP '^TEST_IMAGE\s*\?=\s*\K.*' Makefile 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "${TEST_IMAGE}" ]; then
    echo "[SUCCESS] Found TEST_IMAGE from Makefile: ${TEST_IMAGE}"
  else
    echo "[WARN] Could not extract TEST_IMAGE from Makefile"
  fi

  APPROVED_IMAGE=$(grep -oP '^APPROVED_IMAGE\s*\?=\s*\K.*' Makefile 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "${APPROVED_IMAGE}" ]; then
    echo "[SUCCESS] Found APPROVED_IMAGE from Makefile: ${APPROVED_IMAGE}"
  else
    echo "[WARN] Could not extract APPROVED_IMAGE from Makefile"
  fi
else
  echo "[WARN] Makefile not found"
fi

if [ -n "${TEST_IMAGE}" ]; then
  echo "[INFO] Pre-loading TEST_IMAGE to Kind node..."
  if docker exec kind-control-plane crictl pull "${TEST_IMAGE}" 2>/dev/null || true; then
    echo "[SUCCESS] TEST_IMAGE pre-loaded: ${TEST_IMAGE}"
  else
    echo "[WARN] Failed to pre-load TEST_IMAGE (non-critical, test will pull it later)"
  fi
fi

if [ -n "${APPROVED_IMAGE}" ]; then
  echo "[INFO] Pre-loading APPROVED_IMAGE to Kind node..."
  if docker exec kind-control-plane crictl pull "${APPROVED_IMAGE}" 2>/dev/null || true; then
    echo "[SUCCESS] APPROVED_IMAGE pre-loaded: ${APPROVED_IMAGE}"
  else
    echo "[WARN] Failed to pre-load APPROVED_IMAGE (non-critical, test will pull it later)"
  fi
fi

echo "[INFO] Image pre-loading completed (failures here do not affect test outcome)"

echo "[INFO] Running integration tests..."
TEST_EXIT_CODE=0
make integration-tests || TEST_EXIT_CODE=$?

# ============================================================
# Collect diagnostics from remaining test namespaces (failed tests)
# Passed tests cleanup their namespaces, so only failed test namespaces remain
# ============================================================
echo "[INFO] Checking for remaining test namespaces (failed tests)..."

TEST_NAMESPACES=$(kubectl get namespaces -o name 2>/dev/null | grep "namespace/test-" | cut -d/ -f2 || true)

if [ -n "${TEST_NAMESPACES}" ]; then
  NAMESPACE_COUNT=$(echo "${TEST_NAMESPACES}" | wc -l)
  echo "[INFO] Found ${NAMESPACE_COUNT} test namespace(s) - these tests failed:"
  echo "${TEST_NAMESPACES}" | sed 's/^/  - /'

  echo "[INFO] Collecting diagnostics using must-gather..."
  MUST_GATHER_DIR="/tmp/must-gather-failed-tests-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${MUST_GATHER_DIR}"

  if [ -f "./must-gather/gather" ]; then
    # Run the existing gather script - it will collect from all namespaces
    # Since only failed test namespaces remain, it will only collect those
    echo "[INFO] Running must-gather/gather script..."
    KUBECTL=kubectl COLLECTION_PATH="${MUST_GATHER_DIR}" ./must-gather/gather 2>&1 | tee "${MUST_GATHER_DIR}/gather.log"

    if [ $? -eq 0 ]; then
      echo "[SUCCESS] Diagnostics collected to ${MUST_GATHER_DIR}"

      # Show what was collected
      echo "[INFO] Collected diagnostics:"
      find "${MUST_GATHER_DIR}" -type f 2>/dev/null | sed 's/^/    /' | head -20
      FILE_COUNT=$(find "${MUST_GATHER_DIR}" -type f 2>/dev/null | wc -l)
      [ ${FILE_COUNT} -gt 20 ] && echo "    ... and $((FILE_COUNT - 20)) more files"
    else
      echo "[WARN] must-gather encountered some errors (check ${MUST_GATHER_DIR}/gather.log)"
    fi
  else
    echo "[WARN] must-gather/gather script not found, using fallback kubectl collection..."

    # Fallback: simple kubectl collection
    for ns in ${TEST_NAMESPACES}; do
      echo "[INFO] Collecting diagnostics from namespace: ${ns}"
      kubectl get all,trustedexecutioncluster,approvedimage,machine,virtualmachine,virtualmachineinstance \
        -n "${ns}" -o yaml > "${MUST_GATHER_DIR}/resources-${ns}.yaml" 2>&1 || true
      kubectl get events -n "${ns}" --sort-by='.lastTimestamp' \
        > "${MUST_GATHER_DIR}/events-${ns}.txt" 2>&1 || true
      kubectl logs -n "${ns}" --all-containers=true --prefix=true --tail=-1 \
        > "${MUST_GATHER_DIR}/logs-${ns}.txt" 2>&1 || true
    done
    echo "[SUCCESS] Basic diagnostics collected to ${MUST_GATHER_DIR}"
  fi

  # Summary
  echo ""
  echo "=========================================="
  echo "Diagnostic Collection Summary"
  echo "=========================================="
  echo "Failed test namespaces: ${NAMESPACE_COUNT}"
  echo "Diagnostics location: ${MUST_GATHER_DIR}"
  echo "=========================================="

else
  echo "[SUCCESS] No remaining test namespaces - all tests passed!"
fi

# Exit with test result if tests failed
if [ ${TEST_EXIT_CODE} -ne 0 ]; then
  echo "[ERROR] Integration tests failed with exit code ${TEST_EXIT_CODE}"
  exit ${TEST_EXIT_CODE}
fi

echo "[SUCCESS] Integration tests completed successfully"

echo "[INFO] Collecting test results and cluster state..."
kubectl get all -A > /tmp/operator-install-logs/cluster-all-resources.yaml 2>&1 || true
kubectl get nodes -o wide > /tmp/operator-install-logs/nodes.yaml 2>&1 || true

# Cleanup ssh-agent we started
if [ -n "${SSH_AGENT_PID:-}" ]; then
  echo "[INFO] Cleaning up ssh-agent (PID: ${SSH_AGENT_PID})..."
  kill "${SSH_AGENT_PID}" 2>/dev/null || echo "[WARN] Could not kill ssh-agent"
else
  echo "[WARN] SSH_AGENT_PID not set, cannot cleanup ssh-agent"
fi

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
  mkdir -p "${ARTIFACT_DIR}/must-gather"

  # Collect test logs
  log_info "Collecting test logs from Beaker machine..."
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-install-logs/*" \
    "${ARTIFACT_DIR}/operator-test-logs/" 2>&1 || log_warn "Failed to collect test logs"

  # Collect must-gather diagnostics from failed tests
  log_info "Collecting must-gather diagnostics from Beaker machine..."

  if ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" "ls -d /tmp/must-gather-failed-tests-* 2>/dev/null" | grep -q must-gather; then
    scp "${SSHOPTS[@]}" -r \
      "${BEAKER_USER}@${BEAKER_IP}:/tmp/must-gather-failed-tests-*" \
      "${ARTIFACT_DIR}/must-gather/" 2>&1 || log_warn "Failed to collect diagnostics"

    log_success "Must-gather diagnostics collected to ${ARTIFACT_DIR}/must-gather/"

    # Show summary of collected diagnostics
    log_info "Collected diagnostic directories:"
    ls -lh "${ARTIFACT_DIR}/must-gather/" 2>/dev/null | tail -n +2 | while read -r line; do
      dir_name=$(echo "$line" | awk '{print $9}')
      file_count=$(find "${ARTIFACT_DIR}/must-gather/${dir_name}" -type f 2>/dev/null | wc -l)
      log_info "  ${dir_name}: ${file_count} files"
    done
  else
    log_info "No must-gather diagnostics found (all tests may have passed before failure)"
  fi

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
