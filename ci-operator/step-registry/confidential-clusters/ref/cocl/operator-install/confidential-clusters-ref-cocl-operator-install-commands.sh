#!/bin/bash

# Operator Installation Step - Builds and deploys cocl-operator on Beaker machine
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
echo "CoCl Operator Installation - Starting"
echo "=========================================="
echo "This script builds and deploys cocl-operator on Beaker machine"
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
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-900}"

# Operator configuration
COCL_OPERATOR_REPO="${COCL_OPERATOR_REPO:-https://github.com/confidential-clusters/cocl-operator.git}"
COCL_OPERATOR_BRANCH="${COCL_OPERATOR_BRANCH:-main}"
COCL_OPERATOR_PATCH_URL="${COCL_OPERATOR_PATCH_URL:-}"

# Progress tracking
TOTAL_STEPS=7
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

# Set defaults for variables not in beaker_info (from environment or defaults)
COCL_OPERATOR_PATCH_URL="${COCL_OPERATOR_PATCH_URL:-}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-900}"

log_info "=== Configuration Summary ==="
log_info "Beaker machine: ${BEAKER_IP}"
log_info "Beaker user: ${BEAKER_USER}"
log_info "Container runtime: ${CONTAINER_RUNTIME}"
log_info "Operator repository: ${COCL_OPERATOR_REPO}"
log_info "Operator branch: ${COCL_OPERATOR_BRANCH}"
log_info "Patch URL: '${COCL_OPERATOR_PATCH_URL}' (${#COCL_OPERATOR_PATCH_URL} chars)"
log_info "Pod ready timeout: ${POD_READY_TIMEOUT}s"
log_info ""
# Convert empty COCL_OPERATOR_PATCH_URL to special marker for SSH transmission
# SSH drops empty string arguments, so we use "-" as placeholder
COCL_OPERATOR_PATCH_URL_ARG="${COCL_OPERATOR_PATCH_URL:-"-"}"
if [ -z "${COCL_OPERATOR_PATCH_URL}" ]; then
  COCL_OPERATOR_PATCH_URL_ARG="-"
fi

log_info "=== SSH Parameters (will pass 5 arguments) ==="
log_info "  \$1 = '${COCL_OPERATOR_REPO}'"
log_info "  \$2 = '${COCL_OPERATOR_BRANCH}'"
log_info "  \$3 = '${COCL_OPERATOR_PATCH_URL_ARG}' (COCL_OPERATOR_PATCH_URL, '-' means empty)"
log_info "  \$4 = '${CONTAINER_RUNTIME}' (CONTAINER_RUNTIME)"
log_info "  \$5 = '${POD_READY_TIMEOUT}' (POD_READY_TIMEOUT)"
log_info "====================================="

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
# Install CoCl Operator on Beaker Machine
# ============================================================================

progress "Installing cocl-operator on Beaker machine"

log_info "Executing operator installation on Beaker machine..."

if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${COCL_OPERATOR_REPO}" "${COCL_OPERATOR_BRANCH}" "${COCL_OPERATOR_PATCH_URL_ARG}" \
  "${CONTAINER_RUNTIME}" "${POD_READY_TIMEOUT}" << 'EOF'

set -euo pipefail
set -x

COCL_OPERATOR_REPO="$1"
COCL_OPERATOR_BRANCH="$2"
COCL_OPERATOR_PATCH_URL="$3"
CONTAINER_RUNTIME="$4"
POD_READY_TIMEOUT="$5"

# Convert "-" placeholder back to empty string
# (SSH drops empty string arguments, so we use "-" as placeholder)
if [ "${COCL_OPERATOR_PATCH_URL}" = "-" ]; then
  COCL_OPERATOR_PATCH_URL=""
fi

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Date: $(date)"
echo "=========================================="
echo "[DEBUG] Received SSH parameters:"
echo "  COCL_OPERATOR_REPO: ${COCL_OPERATOR_REPO}"
echo "  COCL_OPERATOR_BRANCH: ${COCL_OPERATOR_BRANCH}"
echo "  COCL_OPERATOR_PATCH_URL: '${COCL_OPERATOR_PATCH_URL}' (after conversion)"
echo "  CONTAINER_RUNTIME: ${CONTAINER_RUNTIME}"
echo "  POD_READY_TIMEOUT: ${POD_READY_TIMEOUT}"
echo "=========================================="

# Create log directory
mkdir -p /tmp/operator-install-logs
exec > >(tee -a /tmp/operator-install-logs/installation.log)
exec 2>&1

# Source system-wide profiles to ensure Go and Rust commands are in our PATH
if [ -f "/etc/profile.d/go.sh" ]; then
    source "/etc/profile.d/go.sh"
fi
if [ -f "/etc/profile.d/rust.sh" ]; then
    source "/etc/profile.d/rust.sh"
fi

# Note: SSH firewall guardian (from beaker-kind-provision step) handles firewall automatically

# Determine if sudo is needed
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# ============================================================================
# Clone cocl-operator Repository and Apply Patch
# ============================================================================
echo "[INFO] Cloning cocl-operator repository..."

WORK_DIR="${HOME}/cocl-operator"
rm -rf "${WORK_DIR}"

# Clone the repository using the specified branch
echo "[INFO] Cloning branch '${COCL_OPERATOR_BRANCH}' from '${COCL_OPERATOR_REPO}'"
git clone --branch "${COCL_OPERATOR_BRANCH}" "${COCL_OPERATOR_REPO}" "${WORK_DIR}"
cd "${WORK_DIR}"

# Apply patch if URL is provided
if [ -n "${COCL_OPERATOR_PATCH_URL}" ]; then
  echo "[INFO] Applying patch from ${COCL_OPERATOR_PATCH_URL}"
  curl -L "${COCL_OPERATOR_PATCH_URL}" | git apply
  echo "[SUCCESS] Patch applied"
else
  echo "[INFO] No patch URL provided, skipping patch application"
fi

# Patch Containerfile to add GOPROXY environment variables
# This is necessary because the container build runs in an isolated environment
# and won't inherit GOPROXY from the host, causing Go module downloads to fail
echo "[INFO] Patching Containerfile to add GOPROXY configuration..."
if [ -f "Containerfile" ]; then
  # Backup original
  cp Containerfile Containerfile.orig

  # Insert ENV directives after the FROM line but before any RUN commands
  # This ensures GOPROXY is available for all go install/go build commands
  sed -i '/^FROM.*AS builder/a\
# CI: Configure Go module proxy to avoid network timeout\
ENV GOPROXY="https://goproxy.cn,https://goproxy.io,direct"\
ENV GOSUMDB="sum.golang.org"' Containerfile

  echo "[INFO] Containerfile patched. Showing diff:"
  diff -u Containerfile.orig Containerfile || true
  echo "[SUCCESS] Containerfile ready for build"
else
  echo "[WARN] Containerfile not found, skipping patch"
fi

# Patch Makefile and related files to force docker instead of podman
# The repository may have hardcoded 'podman' commands which don't work in all CI environments
echo "[INFO] Patching repository files to use docker instead of podman..."

# Patch Makefile
if [ -f "Makefile" ]; then
  echo "[INFO] Patching Makefile..."
  cp Makefile Makefile.orig

  # Replace all instances of 'podman' with 'docker'
  sed -i 's/podman/docker/g' Makefile

  # Also ensure RUNTIME variable defaults to docker if used
  sed -i 's/RUNTIME ?= podman/RUNTIME ?= docker/g' Makefile
  sed -i 's/RUNTIME := podman/RUNTIME := docker/g' Makefile

  echo "[INFO] Makefile patched. Lines with 'docker':"
  grep -n "docker" Makefile | head -10 || echo "  (no matches)"
else
  echo "[WARN] Makefile not found"
fi

# Patch any shell scripts that might use podman
echo "[INFO] Checking for shell scripts with podman commands..."
SCRIPT_FILES=$(find . -maxdepth 3 -type f \( -name "*.sh" -o -name "*.bash" \) 2>/dev/null || true)
if [ -n "${SCRIPT_FILES}" ]; then
  for script in ${SCRIPT_FILES}; do
    if grep -q "podman" "${script}" 2>/dev/null; then
      echo "[INFO] Patching ${script}..."
      cp "${script}" "${script}.orig"
      sed -i 's/podman/docker/g' "${script}"
      echo "[INFO] ${script}: replaced podman with docker"
    fi
  done
else
  echo "[INFO] No shell scripts found to patch"
fi

# Patch configuration files (YAML, etc.)
echo "[INFO] Checking for configuration files with podman references..."
CONFIG_FILES=$(find . -maxdepth 3 -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null || true)
if [ -n "${CONFIG_FILES}" ]; then
  for config in ${CONFIG_FILES}; do
    if grep -q "podman" "${config}" 2>/dev/null; then
      echo "[INFO] Patching ${config}..."
      cp "${config}" "${config}.orig"
      sed -i 's/podman/docker/g' "${config}"
      echo "[INFO] ${config}: replaced podman with docker"
    fi
  done
else
  echo "[INFO] No config files found to patch"
fi

# Patch scripts/common.sh to fix DOCKER_HOST for root docker
echo "[INFO] Checking for scripts/common.sh to fix DOCKER_HOST..."
if [ -f "scripts/common.sh" ]; then
  echo "[INFO] Patching scripts/common.sh..."
  cp scripts/common.sh scripts/common.sh.orig

  # Remove or fix the incorrect DOCKER_HOST setting
  # Root docker uses /var/run/docker.sock (default), not /run/user/0/docker/docker.sock
  sed -i '/export DOCKER_HOST=unix:\/\/\/run\/user\/0\/docker\/docker.sock/d' scripts/common.sh

  # Also remove any KIND_EXPERIMENTAL_PROVIDER=docker that might cause issues
  # KIND works fine with docker without this experimental flag
  sed -i '/export KIND_EXPERIMENTAL_PROVIDER=docker/d' scripts/common.sh

  echo "[INFO] scripts/common.sh patched. Changes:"
  diff -u scripts/common.sh.orig scripts/common.sh || true
else
  echo "[INFO] scripts/common.sh not found, skipping"
fi

echo "[SUCCESS] Repository patched to use docker"
echo "[SUCCESS] Repository is ready"

# ============================================================================
# Ensure Local Registry is Running
# ============================================================================
echo "[INFO] Checking if local registry (kind-registry) is running..."

# Check if kind-registry container exists and is running
REG_NAME="kind-registry"
REG_PORT="5000"
REG_RUNNING=$(docker ps -q -f name=${REG_NAME} 2>/dev/null || true)

if [ -n "${REG_RUNNING}" ]; then
  echo "[INFO] Registry ${REG_NAME} is already running (container ID: ${REG_RUNNING})"
else
  echo "[WARN] Registry ${REG_NAME} is not running"

  # Check if container exists but is stopped
  REG_EXISTS=$(docker ps -aq -f name=${REG_NAME} 2>/dev/null || true)

  if [ -n "${REG_EXISTS}" ]; then
    echo "[INFO] Registry container exists but is stopped, starting it..."
    docker start ${REG_NAME}
  else
    echo "[INFO] Creating new registry container..."
    # Remove any existing container with the same name
    docker rm -f ${REG_NAME} 2>/dev/null || true

    # Create and start the registry
    docker run -d --restart=always \
      -p "127.0.0.1:${REG_PORT}:5000" \
      --network kind \
      --name ${REG_NAME} \
      registry:2 || {
        echo "[ERROR] Failed to create registry container"
        echo "[INFO] Trying without --network kind (will add later)..."
        docker run -d --restart=always \
          -p "127.0.0.1:${REG_PORT}:5000" \
          --name ${REG_NAME} \
          registry:2

        # Connect to kind network
        echo "[INFO] Connecting registry to kind network..."
        docker network connect kind ${REG_NAME} 2>/dev/null || echo "[WARN] Could not connect to kind network"
      }
  fi

  # Verify registry is running
  sleep 2
  if docker ps -q -f name=${REG_NAME} >/dev/null 2>&1; then
    echo "[SUCCESS] Registry ${REG_NAME} is now running"
  else
    echo "[ERROR] Failed to start registry ${REG_NAME}"
    docker ps -a -f name=${REG_NAME}
    docker logs ${REG_NAME} 2>&1 || true
    exit 1
  fi
fi

# Test registry connectivity
echo "[INFO] Testing registry connectivity..."
if curl -s http://localhost:${REG_PORT}/v2/_catalog >/dev/null 2>&1; then
  echo "[SUCCESS] Registry is accessible at localhost:${REG_PORT}"
  echo "[INFO] Registry catalog:"
  curl -s http://localhost:${REG_PORT}/v2/_catalog | head -5 || true
else
  echo "[ERROR] Registry is not accessible at localhost:${REG_PORT}"
  echo "[INFO] Registry container status:"
  docker ps -a -f name=${REG_NAME}
  echo "[INFO] Registry logs:"
  docker logs ${REG_NAME} 2>&1 | tail -20 || true
  exit 1
fi

# Note: SSH firewall guardian handles any iptables changes from Docker operations

# ============================================================================
# Deploy Operator
# ============================================================================

# Set up the environment
# The IP 192.168.122.1 is the default for the libvirt network on the host
export IP="192.168.122.1"
export RUNTIME="${CONTAINER_RUNTIME}"

# Configure Go module proxy to avoid network timeout issues
# Use goproxy.cn (China mirror) as primary, with direct fallback
export GOPROXY="https://goproxy.cn,https://goproxy.io,direct"
export GOSUMDB="sum.golang.org"

echo "[INFO] Environment configured:"
echo "  IP=${IP}"
echo "  RUNTIME=${RUNTIME}"
echo "  WORK_DIR=${WORK_DIR}"
echo "  GOPROXY=${GOPROXY}"

echo "[INFO] Building and pushing container images to the local registry..."

# Build and push the container images
# Pass GOPROXY to container build process via BUILDAH_COMMON_BUILD_ARGS
# This ensures Go module downloads work even if proxy.golang.org is unreachable
export BUILDAH_COMMON_BUILD_ARGS="--build-arg GOPROXY=${GOPROXY} --build-arg GOSUMDB=${GOSUMDB}"
make REGISTRY=localhost:5000 push BUILD_TYPE=debug RUNTIME="${RUNTIME}"

echo "[INFO] Generating code and CRD definitions..."
# Some operators require 'make generate' to create CRD definitions
# Check if generate target exists in Makefile
if grep -q "^generate:" Makefile; then
  echo "[INFO] Running 'make generate' to generate CRD definitions..."
  make generate RUNTIME="${RUNTIME}" || echo "[WARN] 'make generate' failed, continuing anyway"
else
  echo "[INFO] No 'generate' target found in Makefile, skipping"
fi

echo "[INFO] Generating manifests..."
make REGISTRY=localhost:5000 manifests RUNTIME="${RUNTIME}"

echo "[INFO] Checking generated files and directory structure..."
echo "[DEBUG] Contents of config directory:"
ls -laR config/ 2>/dev/null || echo "  config/ directory not found"

echo ""
echo "[DEBUG] Searching for CRD files:"
find . -name "*.yaml" -path "*/crd*" -o -name "*crd*.yaml" 2>/dev/null | head -20 || echo "  No CRD files found"

echo ""
echo "[DEBUG] Checking common CRD locations:"
for dir in config/crd config/crds manifests/crd manifests/crds deploy/crds; do
  if [ -d "${dir}" ]; then
    echo "  ✓ ${dir} exists:"
    ls -la "${dir}" | head -10
  else
    echo "  ✗ ${dir} does not exist"
  fi
done

echo ""
echo "[INFO] Preparing for operator installation..."

# Check if config/crd exists, if not, try to find and link CRD files
if [ ! -d "config/crd" ]; then
  echo "[WARN] config/crd directory not found, searching for CRD files..."

  # Check alternative locations
  if [ -d "config/crds" ]; then
    echo "[INFO] Found config/crds, creating symlink to config/crd"
    ln -s crds config/crd
  elif [ -d "manifests/crd" ]; then
    echo "[INFO] Found manifests/crd, creating symlink to config/crd"
    mkdir -p config
    ln -s ../manifests/crd config/crd
  elif [ -d "deploy/crds" ]; then
    echo "[INFO] Found deploy/crds, creating symlink to config/crd"
    mkdir -p config
    ln -s ../deploy/crds config/crd
  else
    # Try to find CRD files anywhere and copy them
    echo "[INFO] Searching for CRD YAML files in the repository..."
    CRD_FILES=$(find . -name "*trustedexecutioncluster*.yaml" -o -name "*crd*.yaml" | grep -v ".orig" | head -10)

    if [ -n "${CRD_FILES}" ]; then
      echo "[INFO] Found CRD files, creating config/crd directory:"
      echo "${CRD_FILES}"
      mkdir -p config/crd
      for crd in ${CRD_FILES}; do
        echo "[INFO] Copying ${crd} to config/crd/"
        cp "${crd}" config/crd/
      done
    else
      echo "[ERROR] No CRD files found in repository"
      echo "[ERROR] This might indicate the repository structure has changed"
      echo "[INFO] Attempting to continue anyway..."
    fi
  fi
else
  echo "[INFO] config/crd directory exists"
fi

echo ""
echo "[INFO] Installing the operator..."
make TRUSTEE_ADDR="${IP}" install RUNTIME="${RUNTIME}" || {
  echo "[ERROR] 'make install' failed"
  echo "[INFO] Checking Makefile install target:"
  grep -A 10 "^install:" Makefile || echo "  (install target not found)"
  exit 1
}

echo "[SUCCESS] cocl-operator installation complete"

# ============================================================================
# Verify Cluster and CoCl Health
# ============================================================================

echo "--- Verifying Kubernetes Cluster Node Status ---"
echo "$ kubectl get nodes -o wide"
if ! kubectl get nodes -o wide; then
    echo "[ERROR] Failed to get node status. Please check your kubectl configuration and cluster."
    exit 1
fi
echo "--- Nodes are running ---"

echo ""

echo "--- Verifying Pod Status in 'confidential-clusters' Namespace ---"
echo "$ kubectl get pods -n confidential-clusters -o wide"
if ! kubectl get pods -n confidential-clusters -o wide; then
    echo "[ERROR] Failed to get pods from the 'confidential-clusters' namespace."
    exit 1
fi

echo ""

echo "--- Waiting for pods in 'confidential-clusters' namespace to be running ---"
TIMEOUT="${POD_READY_TIMEOUT}"
SECONDS=0
while [ $SECONDS -lt $TIMEOUT ]; do
    echo ""
    echo "--- Checking pod status (elapsed: ${SECONDS}s / ${TIMEOUT}s) ---"

    # Check for pods that have failed completely
    echo "$ kubectl get pods --field-selector=status.phase=Failed -n confidential-clusters -o jsonpath='{.items[*].metadata.name}'"
    FAILED_PHASE_PODS=$(kubectl get pods --field-selector=status.phase=Failed -n confidential-clusters -o jsonpath='{.items[*].metadata.name}')
    if [ -n "$FAILED_PHASE_PODS" ]; then
        echo "[ERROR] The following pods have failed:"
        for pod in $FAILED_PHASE_PODS;
        do
            echo "  - $pod"
            echo "$ kubectl describe pod \"$pod\" -n confidential-clusters"
            kubectl describe pod "$pod" -n confidential-clusters
        done
        echo "--- Current status of all resources in 'confidential-clusters' namespace ---"
        echo "$ kubectl get all -n confidential-clusters"
        kubectl get all -n confidential-clusters
        exit 1
    fi

    # Check for pods with container errors that prevent them from starting
    echo "$ kubectl get pods -n confidential-clusters -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{range .status.containerStatuses[*]}{.state.waiting.reason}{\" \"}{end}{\"\n\"}{end}' | grep -E \"CrashLoopBackOff|ImagePullBackOff|CreateContainerError|ErrImagePull|CreateContainerConfigError|InvalidImageName\" | awk '{print \$1}' || true"
    ERROR_REASON_PODS=$(kubectl get pods -n confidential-clusters -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' | grep -E "CrashLoopBackOff|ImagePullBackOff|CreateContainerError|ErrImagePull|CreateContainerConfigError|InvalidImageName" | awk '{print $1}' || true)
    if [ -n "$ERROR_REASON_PODS" ]; then
        echo "[ERROR] The following pods have container errors:"
        for pod in $ERROR_REASON_PODS;
        do
            echo "  - $pod"
            echo "$ kubectl describe pod \"$pod\" -n confidential-clusters"
            kubectl describe pod "$pod" -n confidential-clusters
        done
        echo "--- Current status of all resources in 'confidential-clusters' namespace ---"
        echo "$ kubectl get all -n confidential-clusters"
        kubectl get all -n confidential-clusters
        exit 1
    fi

    # Get current pod status for display
    echo "$ kubectl get pods -n confidential-clusters -o wide"
    kubectl get pods -n confidential-clusters -o wide

    # Check if all pods are running or have succeeded
    echo "$ kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -n confidential-clusters -o jsonpath='{.items[*].metadata.name}'"
    NOT_RUNNING_PODS=$(kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -n confidential-clusters -o jsonpath='{.items[*].metadata.name}')
    if [ -z "$NOT_RUNNING_PODS" ]; then
        echo "--- All pods are running. ---"
        echo "--- Final status of all resources in 'confidential-clusters' namespace ---"
        echo "$ kubectl get all -n confidential-clusters"
        kubectl get all -n confidential-clusters
        break
    fi

    echo "[INFO] Still waiting for pods to be ready: $NOT_RUNNING_PODS"
    sleep 10
    SECONDS=$((SECONDS + 10))
done

if [ $SECONDS -ge $TIMEOUT ]; then
    echo "[ERROR] Timeout waiting for pods to be ready after ${TIMEOUT} seconds"
    echo "--- Current status of all resources in 'confidential-clusters' namespace ---"
    echo "$ kubectl get all -n confidential-clusters"
    kubectl get all -n confidential-clusters
    FAILED_PODS=$(kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -n confidential-clusters -o jsonpath='{.items[*].metadata.name}')
    if [ -n "$FAILED_PODS" ]; then
        echo "[ERROR] The following pods are not in a 'Running' or 'Succeeded' state:"
        for pod in $FAILED_PODS;
        do
            echo "  - $pod"
            echo "--- Describing pod: $pod ---"
            echo "$ kubectl describe pod \"$pod\" -n confidential-clusters"
            kubectl describe pod "$pod" -n confidential-clusters
            echo "--- End of description for pod: $pod ---"
        done
    fi
    exit 1
fi

echo "[SUCCESS] All pods are healthy and running"

EOF
then
  log_error "Operator installation failed"
  CRITICAL_FAILURE=true
  DEPLOYMENT_STATUS=1
fi

# Check if installation failed
if $CRITICAL_FAILURE; then
  log_error "Critical failure during operator installation"

  # Collect logs
  mkdir -p "${ARTIFACT_DIR}/operator-install-logs"
  scp "${SSHOPTS[@]}" \
    "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-install-logs/*.log" \
    "${ARTIFACT_DIR}/operator-install-logs/" 2>&1 || log_warn "Failed to collect installation logs"

  exit ${DEPLOYMENT_STATUS}
fi

log_success "cocl-operator installed successfully"

# ============================================================================
# Collect Cluster State and Logs
# ============================================================================

progress "Collecting cluster state and logs"

mkdir -p "${ARTIFACT_DIR}/operator-install-logs"

# Collect installation logs
scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-install-logs/*.log" \
  "${ARTIFACT_DIR}/operator-install-logs/" 2>&1 || log_warn "Failed to collect installation logs"

# Collect cluster state using kubeconfig from previous step
if [ -f "${SHARED_DIR}/kubeconfig" ]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"

  log_info "Collecting cluster state..."
  kubectl get all -A > "${ARTIFACT_DIR}/operator-install-logs/cluster-all-resources.yaml" 2>&1 || true
  kubectl get pods -n confidential-clusters -o yaml > "${ARTIFACT_DIR}/operator-install-logs/cocl-pods.yaml" 2>&1 || true
  kubectl get pods -n confidential-clusters -o wide > "${ARTIFACT_DIR}/operator-install-logs/cocl-pods-wide.txt" 2>&1 || true
  kubectl describe pods -n confidential-clusters > "${ARTIFACT_DIR}/operator-install-logs/cocl-pods-describe.txt" 2>&1 || true

  log_success "Cluster state collected"
else
  log_warn "kubeconfig not found, skipping cluster state collection"
fi

# ============================================================================
# Verify Operator Health from CI Pod
# ============================================================================

progress "Verifying operator health from CI pod"

if [ -f "${SHARED_DIR}/kubeconfig" ]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"

  log_info "Checking pods in confidential-clusters namespace..."
  kubectl get pods -n confidential-clusters -o wide

  log_info "Checking all resources..."
  kubectl get all -n confidential-clusters

  log_success "Operator verification complete"
else
  log_warn "kubeconfig not found, skipping health verification"
fi

# ============================================================================
# Final Status
# ============================================================================

echo ""
echo "=========================================="
echo "CoCl Operator Installation - Completed Successfully"
echo "=========================================="
echo "Operator Repository: ${COCL_OPERATOR_REPO}"
echo "Operator Branch: ${COCL_OPERATOR_BRANCH}"
echo "Beaker Machine: ${BEAKER_IP}"
echo "Container Runtime: ${CONTAINER_RUNTIME}"
echo ""
echo "All pods in confidential-clusters namespace are healthy and running"
echo ""
echo "Logs collected to: ${ARTIFACT_DIR}/operator-install-logs/"
echo "=========================================="
date
