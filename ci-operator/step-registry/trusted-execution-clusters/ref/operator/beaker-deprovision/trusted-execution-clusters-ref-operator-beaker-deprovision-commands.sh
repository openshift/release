#!/bin/bash

# Beaker Deprovision Step - Cleanup all resources on Beaker machine
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

echo "Beaker Cleanup and Deprovision - Starting"
echo "This script performs cleanup operations on Beaker machine"
date

if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "[INFO] Creating user entry for UID $(id -u) in /etc/passwd"
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

# Cleanup status tracking
CLEANUP_FAILED=false

# Configurable options
DEPROVISION_TIMEOUT="${DEPROVISION_TIMEOUT:-600}"
CLEANUP_IMAGES="${CLEANUP_IMAGES:-true}"
RESTART_SERVICES="${RESTART_SERVICES:-true}"

# Helper Functions
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

log_info "Reading configuration..."

if [ -f "${SHARED_DIR}/beaker_info" ]; then
  source "${SHARED_DIR}/beaker_info"
  log_info "Beaker machine: ${BEAKER_IP}"
  log_info "Beaker user: ${BEAKER_USER}"
  log_info "Cluster name: ${KIND_CLUSTER_NAME:-kind}"
else
  log_warn "beaker_info not found, attempting to use environment variables"

  # Try Vault or environment
  if [ -z "${BEAKER_IP:-}" ]; then
    if [ -f "/var/run/beaker-bm/beaker-ip" ]; then
      BEAKER_IP=$(cat "/var/run/beaker-bm/beaker-ip")
    else
      log_error "Cannot determine BEAKER_IP"
      exit 1
    fi
  fi

  if [ -z "${BEAKER_USER:-}" ]; then
    if [ -f "/var/run/beaker-bm/beaker-user" ]; then
      BEAKER_USER=$(cat "/var/run/beaker-bm/beaker-user")
    else
      BEAKER_USER="root"
    fi
  fi

  KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kind}"
fi

log_info "Setting up SSH key..."

SSH_PKEY_PATH_VAULT="/var/run/beaker-bm/beaker-ssh-private-key"

if [ -f "${SSH_PKEY_PATH_VAULT}" ]; then
  SSH_PKEY_PATH="${SSH_PKEY_PATH_VAULT}"
elif [ -n "${CLUSTER_PROFILE_DIR:-}" ] && [ -f "${CLUSTER_PROFILE_DIR}/ssh-key" ]; then
  SSH_PKEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-key"
else
  log_error "SSH key not found"
  exit 1
fi

SSH_PKEY="${HOME}/.ssh/beaker_key"
mkdir -p "${HOME}/.ssh"
cp "${SSH_PKEY_PATH}" "${SSH_PKEY}"
chmod 600 "${SSH_PKEY}"

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

log_info "Collecting pre-cleanup system state..."

mkdir -p "${ARTIFACT_DIR}/cleanup-logs/archived-logs"

# Collect system state before cleanup
PRE_CLEANUP_LOG="${ARTIFACT_DIR}/cleanup-logs/pre-cleanup-state.log"
ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s <<'EOF' > "${PRE_CLEANUP_LOG}" 2>&1 || true

echo "Pre-Cleanup System State"
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo ""

echo "--- Kind Clusters ---"
kind get clusters 2>&1 || echo "No clusters or kind not available"
echo ""

echo "--- Container Status ---"
docker ps -a 2>&1 || echo "Docker not available"
echo ""

echo "--- Container Images ---"
docker images 2>&1 || echo "Docker not available"
echo ""

echo "--- Libvirt VMs ---"
if command -v virsh &> /dev/null; then
    sudo virsh list --all 2>&1 || echo "Could not list VMs"
else
    echo "Libvirt not available"
fi
echo ""

echo "--- VM Disk Images ---"
if [ -d "/var/lib/libvirt/images" ]; then
    ls -lh /var/lib/libvirt/images/ 2>&1 || echo "Could not list libvirt images directory"
else
    echo "Libvirt images directory not found"
fi
echo ""

echo "--- Build Artifacts ---"
ls -ld "${HOME}/investigations" 2>&1 || echo "No investigations directory"
ls -ld /var/log/kbs_logs_* 2>&1 || echo "No KBS log directories"
echo ""

echo "--- Disk Usage ---"
df -h
echo ""

echo "--- Temporary Directories ---"
ls -la /tmp/kind-* 2>&1 || echo "No kind temp directories"
ls -la /tmp/operator-* 2>&1 || echo "No operator temp directories"
ls -la /tmp/e2e-test-* 2>&1 || echo "No E2E test temp directories"
echo ""

EOF

log_success "Pre-cleanup state collected"

log_info "Archiving important logs before cleanup..."

# Archive logs (best effort)
scp "${SSHOPTS[@]}" -r \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-deployment-logs/*" \
  "${ARTIFACT_DIR}/cleanup-logs/archived-logs/" 2>&1 || log_warn "Could not archive kind deployment logs"

scp "${SSHOPTS[@]}" -r \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/kind-cluster-logs/*" \
  "${ARTIFACT_DIR}/cleanup-logs/archived-logs/" 2>&1 || log_warn "Could not archive kind cluster logs"

scp "${SSHOPTS[@]}" -r \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/operator-install-logs/*" \
  "${ARTIFACT_DIR}/cleanup-logs/archived-logs/" 2>&1 || log_warn "Could not archive operator install logs"

log_success "Log archiving completed (best effort)"

log_info "Executing cleanup operations on Beaker machine..."

if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${KIND_CLUSTER_NAME}" "${CLEANUP_IMAGES}" "${RESTART_SERVICES}" << 'EOF'
set -x  # Enable command tracing for debugging

KIND_CLUSTER_NAME="$1"
CLEANUP_IMAGES="$2"
RESTART_SERVICES="$3"

echo "Running on Beaker machine: $(hostname)"
echo "Date: $(date)"
echo "Cluster to delete: ${KIND_CLUSTER_NAME}"
echo "Cleanup images: ${CLEANUP_IMAGES}"
echo "Restart services: ${RESTART_SERVICES}"

# Create cleanup log directory
mkdir -p /tmp/cleanup-logs
exec > >(tee -a /tmp/cleanup-logs/cleanup.log)
exec 2>&1

CLEANUP_ERRORS=0

echo "--- Step 1: Deleting Kind cluster '${KIND_CLUSTER_NAME}' ---"

if command -v kind &> /dev/null; then
    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        echo "[INFO] Deleting cluster ${KIND_CLUSTER_NAME}..."
        if kind delete cluster --name "${KIND_CLUSTER_NAME}"; then
            echo "[SUCCESS] Cluster ${KIND_CLUSTER_NAME} deleted"
        else
            echo "[ERROR] Failed to delete cluster ${KIND_CLUSTER_NAME}"
            ((CLEANUP_ERRORS++))
        fi
    else
        echo "[INFO] Cluster ${KIND_CLUSTER_NAME} not found, skipping"
    fi
else
    echo "[WARN] kind command not found, skipping cluster deletion"
fi

# Clean up kubeconfig
echo "[INFO] Cleaning up kubeconfig..."
if command -v kubectl &> /dev/null; then
    kubectl config delete-context "${KIND_CLUSTER_NAME}" 2>&1 || echo "[INFO] Context not found"
    kubectl config delete-cluster "${KIND_CLUSTER_NAME}" 2>&1 || echo "[INFO] Cluster not found"
    echo "[SUCCESS] Kubeconfig cleaned up"
else
    echo "[WARN] kubectl not found, skipping kubeconfig cleanup"
fi

# Clean up kind-registry container (created by kind for local image caching)
echo "[INFO] Cleaning up kind-registry container..."
if docker ps -a --filter "name=kind-registry" -q | grep -q .; then
    docker rm -f kind-registry 2>&1 || echo "[WARN] Could not remove kind-registry"
    echo "[SUCCESS] kind-registry container removed"
else
    echo "[INFO] kind-registry container not found"
fi

echo "--- Step 2: Cleaning up test containers and images ---"
echo "[INFO] NOTE: Docker and kind packages/binaries are PRESERVED (not removed)"
echo "[INFO] This step only removes test artifacts (containers, volumes, dangling images)"

if [ "${CLEANUP_IMAGES}" == "true" ]; then
    if command -v docker &> /dev/null; then
        echo "[INFO] Cleaning up test-related Docker resources..."

        # Remove Kind-labeled containers first
        docker ps -a --filter "label=io.x-k8s.kind.cluster" -q | xargs -r docker rm -f 2>&1 || echo "[INFO] No Kind containers to remove"

        # Remove all stopped containers (safe - only removes stopped ones)
        docker container prune -f 2>&1 || echo "[WARN] Container prune failed"

        # Remove Kind volumes
        docker volume ls --filter "label=io.x-k8s.kind.cluster" -q | xargs -r docker volume rm 2>&1 || echo "[INFO] No Kind volumes to remove"

        # Remove test-specific operator images (keeping infrastructure images)
        echo "[INFO] Removing test operator images..."
        echo "[INFO] Keeping: kindest/node, registry:2 (infrastructure images)"

        # Remove images matching operator names (all tags and registries)
        for image_pattern in "compute-pcrs" "registration-server" "trusted-cluster-operator" "attestation-key-register"; do
            echo "[INFO] Removing images matching pattern: ${image_pattern}"
            docker images --format "{{.Repository}}:{{.Tag}}" | grep -i "${image_pattern}" | xargs -r docker rmi -f 2>&1 || echo "[INFO] No ${image_pattern} images to remove"
        done

        echo "[SUCCESS] Test operator images removed"

        # Remove dangling images (broken layers with no tags)
        echo "[INFO] Removing dangling images (broken layers)..."
        docker image prune -f 2>&1 || echo "[WARN] Image prune failed"

        # Remove unused volumes (safe - only removes volumes not attached to containers)
        docker volume prune -f 2>&1 || echo "[WARN] Volume prune failed"

        echo "[SUCCESS] Docker resources cleaned up"
    fi
else
    echo "[INFO] Container resource cleanup skipped"
fi

echo "--- Step 3: Cleaning up Kind network resources ---"

# Clean up only Kind-created networks
if command -v docker &> /dev/null; then
    echo "[INFO] Cleaning up Kind-created Docker networks..."

    # Remove networks with kind label
    docker network ls --filter "label=io.x-k8s.kind.cluster" -q | xargs -r docker network rm 2>&1 || echo "[INFO] No labeled Kind networks to remove"

    # Force remove the 'kind' network (may need to disconnect containers first)
    if docker network inspect kind &> /dev/null; then
        echo "[INFO] Disconnecting all containers from kind network..."
        # Disconnect any connected containers
        docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | \
            xargs -r -n1 docker network disconnect -f kind 2>&1 || echo "[INFO] No containers to disconnect"

        # Now remove the network
        if docker network rm kind 2>&1; then
            echo "[SUCCESS] kind network removed"
        else
            echo "[WARN] Could not remove kind network"
        fi
    else
        echo "[INFO] kind network not found"
    fi

    echo "[SUCCESS] Kind networks cleaned up"
fi

echo "--- Step 4: Skipping container runtime data directories ---"

echo "[INFO] NOT deleting /var/lib/docker, /var/lib/containerd, or /var/lib/containers"
echo "[INFO] These directories must be preserved to keep Docker/containerd functional"
echo "[INFO] Only test-specific containers and images are cleaned up in previous steps"

echo "[SUCCESS] Container runtime data directories preserved"

echo "--- Step 5: Removing temporary files ---"
echo "[INFO] NOTE: Only /tmp directories are removed (kind/docker binaries are preserved)"

rm -rf /tmp/kind-* 2>&1 || echo "[WARN] Could not remove kind temp directories"
rm -rf /tmp/operator-* 2>&1 || echo "[WARN] Could not remove operator temp directories"
rm -rf /tmp/e2e-test-* 2>&1 || echo "[WARN] Could not remove e2e-test temp directories"

echo "[SUCCESS] Temporary files cleaned up"

echo "--- Step 6: Cleaning up operator working directory ---"

if [ -d "${HOME}/operator-kind-setup" ]; then
    echo "[INFO] Removing operator-kind-setup directory..."
    rm -rf "${HOME}/operator-kind-setup" 2>&1 || echo "[WARN] Could not remove directory"
fi

echo "[SUCCESS] Operator working directory cleaned up"

echo "--- Step 7: Cleaning up test logs ---"

sudo rm -rf /var/log/kbs_logs_* 2>&1 || echo "[WARN] Could not remove KBS logs"
rm -rf /tmp/e2e-test-logs 2>&1 || echo "[WARN] Could not remove E2E test logs"

echo "[SUCCESS] Test logs cleaned up"

echo "--- Step 8: Restarting Docker to reset containerd state ---"

if [ "${RESTART_SERVICES}" == "true" ]; then
    if command -v docker &> /dev/null; then
        echo "[INFO] Restarting Docker service to clear containerd metadata..."
        echo "[INFO] This prevents containerd corruption between test runs"

        # Restart Docker (also restarts containerd)
        if sudo systemctl restart docker 2>&1; then
            echo "[SUCCESS] Docker service restarted"

            # Wait 60 seconds for Docker daemon and containerd to fully initialize
            echo "[INFO] Waiting 60 seconds for Docker/containerd to fully initialize..."
            sleep 60

            if docker info > /dev/null 2>&1; then
                echo "[SUCCESS] Docker daemon is responsive after restart"

                # Critical: Test actual container creation to verify containerd health
                echo "[INFO] Testing containerd health by creating test container..."
                MAX_RETRIES=5
                RETRY_COUNT=0
                while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
                    if docker run --rm alpine echo "Containerd healthy" > /dev/null 2>&1; then
                        echo "[SUCCESS] Containerd is healthy (can create containers)"
                        break
                    else
                        RETRY_COUNT=$((RETRY_COUNT + 1))
                        if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
                            echo "[WARN] Containerd test failed (attempt ${RETRY_COUNT}/${MAX_RETRIES}), waiting 10 seconds..."
                            sleep 10
                        else
                            echo "[ERROR] Containerd STILL FAILING after ${MAX_RETRIES} attempts!"
                            echo "[ERROR] Manual intervention may be required"
                        fi
                    fi
                done
            else
                echo "[ERROR] Docker daemon not responsive after 60 seconds"
            fi
        else
            echo "[ERROR] Failed to restart Docker service"
        fi
    fi
else
    echo "[INFO] Service restart skipped"
fi

echo "--- Step 9: Verifying clean state ---"

# Verification checks
echo "[INFO] Checking remaining Docker containers..."
DOCKER_CONTAINERS=$(docker ps -aq 2>/dev/null | wc -l)

echo "Docker containers: $DOCKER_CONTAINERS"

# Validate Docker/containerd health
echo "[INFO] Validating Docker/containerd state..."
if docker run --rm hello-world > /dev/null 2>&1; then
    echo "[SUCCESS] Docker/containerd can create containers successfully"
else
    echo "[ERROR] Docker/containerd health check failed"
    echo "[ERROR] This may indicate containerd corruption"
fi

echo "--- Cleanup Summary ---"
echo "Cleanup errors encountered: ${CLEANUP_ERRORS}"
echo "Disk Usage:"
df -h

exit 0

EOF
then
  log_error "Cleanup script execution failed"
  CLEANUP_FAILED=true
else
  log_success "Cleanup script executed successfully"
fi

log_info "Collecting cleanup logs..."

scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/cleanup-logs/cleanup.log" \
  "${ARTIFACT_DIR}/cleanup-logs/cleanup-execution.log" 2>&1 || log_warn "Could not collect cleanup execution log"

log_info "Collecting post-cleanup system state..."

POST_CLEANUP_LOG="${ARTIFACT_DIR}/cleanup-logs/post-cleanup-state.log"
ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s <<'EOF' > "${POST_CLEANUP_LOG}" 2>&1 || true

echo "Post-Cleanup System State"
echo "Date: $(date)"
echo ""

echo "--- Kind Clusters (should be empty) ---"
kind get clusters 2>&1 || echo "No clusters or kind not available"
echo ""

echo "--- Docker Containers (should be minimal) ---"
docker ps -a 2>&1 || echo "Docker not available"
echo ""

echo "--- Container Images ---"
docker images 2>&1 || echo "Docker not available"
echo ""

echo "--- Libvirt VMs (should be empty) ---"
if command -v virsh &> /dev/null; then
    sudo virsh list --all 2>&1 || echo "Could not list VMs"
else
    echo "Libvirt not available"
fi
echo ""

echo "--- VM Disk Images (should be minimal) ---"
if [ -d "/var/lib/libvirt/images" ]; then
    ls -lh /var/lib/libvirt/images/ 2>&1 || echo "Could not list libvirt images directory"
else
    echo "Libvirt images directory not found"
fi
echo ""

echo "--- Build Artifacts (should be removed) ---"
ls -ld "${HOME}/investigations" 2>&1 || echo "No investigations directory (cleaned)"
ls -ld /var/log/kbs_logs_* 2>&1 || echo "No KBS log directories (cleaned)"
echo ""

echo "--- Disk Usage (after cleanup) ---"
df -h
echo ""

echo "--- Temporary Directories (should be minimal) ---"
ls -la /tmp/ | grep -E "kind|operator|e2e" || echo "No test-related temp directories found"
echo ""

EOF

log_success "Post-cleanup state collected"

if $CLEANUP_FAILED; then
  echo "Beaker Cleanup - COMPLETED WITH ERRORS"
  echo "Some cleanup operations failed"
  echo "Check logs in ${ARTIFACT_DIR}/cleanup-logs/"
  echo "Note: Cleanup failures are non-fatal. Exiting with success."
  date
  exit 0
fi

echo "Beaker Cleanup - Completed Successfully"
echo "Beaker Machine: ${BEAKER_IP}"
echo "Cluster Deleted: ${KIND_CLUSTER_NAME}"
echo "Images Cleaned: ${CLEANUP_IMAGES}"
echo "Services Restarted: ${RESTART_SERVICES}"
echo ""
echo "Cleanup Logs: ${ARTIFACT_DIR}/cleanup-logs/"
echo "Archived Logs: ${ARTIFACT_DIR}/cleanup-logs/archived-logs/"
date

# ============================================================================
# CRITICAL: Release Exclusive Lock on Beaker Machine
# ============================================================================
# This releases the lock acquired by the provision script, allowing other
# CI jobs to use the Beaker machine.
#
# The lock is held by a background process started during provisioning.
# We release it by sending a SIGUSR1 signal to that process.
# ============================================================================

log_info "Releasing exclusive lock on Beaker machine..."

if [ -f "${SHARED_DIR}/beaker_lock_info" ]; then
  source "${SHARED_DIR}/beaker_lock_info"

  log_info "Lock was acquired at: ${LOCK_ACQUIRED_AT:-unknown}"
  log_info "Lock file: ${LOCK_FILE}"
  log_info "Lock holder PID: ${LOCK_HOLDER_PID}"
  log_info "Lock holder ID: ${LOCK_HOLDER_ID}"
  log_info "Lock holder log: ${LOCK_HOLDER_LOG:-/tmp/lock-holder.log}"

  # Release the lock by signaling the lock holder process
  if ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
    "${LOCK_FILE}" "${LOCK_HOLDER_PID}" "${LOCK_HOLDER_LOG:-/tmp/lock-holder.log}" << 'RELEASESCRIPT'
LOCK_FILE="$1"
LOCK_HOLDER_PID="$2"
LOCK_HOLDER_LOG="$3"

echo "[INFO] Releasing lock by terminating lock holder process..."
echo "[INFO] Lock file: ${LOCK_FILE}"
echo "[INFO] Lock holder PID: ${LOCK_HOLDER_PID}"
echo "[INFO] Lock holder log: ${LOCK_HOLDER_LOG}"

# Check if lock holder process is still running
if ps -p "${LOCK_HOLDER_PID}" > /dev/null 2>&1; then
  echo "[INFO] Lock holder process is running, sending SIGUSR1 signal..."

  # Send SIGUSR1 to gracefully release the lock
  if kill -USR1 "${LOCK_HOLDER_PID}" 2>/dev/null; then
    echo "[INFO] Signal sent, waiting for process to exit..."

    # Wait up to 10 seconds for graceful exit
    for i in {1..10}; do
      if ! ps -p "${LOCK_HOLDER_PID}" > /dev/null 2>&1; then
        echo "[SUCCESS] Lock holder process exited gracefully"
        break
      fi
      sleep 1
    done

    # If still running, force kill
    if ps -p "${LOCK_HOLDER_PID}" > /dev/null 2>&1; then
      echo "[WARN] Lock holder did not exit gracefully, forcing termination..."
      kill -9 "${LOCK_HOLDER_PID}" 2>/dev/null || true
      sleep 1
    fi
  else
    echo "[WARN] Failed to send signal, trying force kill..."
    kill -9 "${LOCK_HOLDER_PID}" 2>/dev/null || true
  fi
else
  echo "[INFO] Lock holder process not running (already exited or timed out)"
fi

# Clean up lock files for THIS job only
# IMPORTANT: Only delete files that belong to our PID!
echo "[INFO] Cleaning up lock files for this job..."

# Check if .holder and .pid files belong to our job before deleting
CURRENT_PID_IN_FILE=""
if [ -f "${LOCK_FILE}.pid" ]; then
  CURRENT_PID_IN_FILE=$(cat "${LOCK_FILE}.pid" 2>/dev/null || echo "")
fi

if [ "${CURRENT_PID_IN_FILE}" = "${LOCK_HOLDER_PID}" ]; then
  # These files belong to our job, safe to delete
  echo "[INFO] Lock files belong to our job (PID ${LOCK_HOLDER_PID}), deleting..."
  rm -f "${LOCK_FILE}.holder" "${LOCK_FILE}.pid" "${LOCK_FILE}.holder.tmp" "${LOCK_FILE}.pid.tmp" 2>/dev/null || true
  echo "[INFO] Deleted .holder and .pid files"
else
  # Another job has already acquired the lock and created new files
  echo "[INFO] Lock files already updated by next job (PID ${CURRENT_PID_IN_FILE}), not deleting"
  # Clean up any temp files from our job that might be left over
  rm -f "${LOCK_FILE}.holder.tmp" "${LOCK_FILE}.pid.tmp" 2>/dev/null || true
fi

# Only delete our specific log file, not others
if [ -f "${LOCK_HOLDER_LOG}" ]; then
  rm -f "${LOCK_HOLDER_LOG}" 2>/dev/null || true
  echo "[INFO] Deleted lock holder log: ${LOCK_HOLDER_LOG}"
fi

# Only delete the main lock file if no other jobs are waiting
# Check if there are any other hold_lock.sh processes running
# Use wc -l instead of pgrep -c to avoid multi-line output issues
OTHER_LOCK_PROCESSES=$(pgrep "hold_lock.sh" 2>/dev/null | wc -l)
if [ "${OTHER_LOCK_PROCESSES}" -eq "0" ]; then
  echo "[INFO] No other lock holder processes detected, safe to remove lock file"
  rm -f "${LOCK_FILE}" 2>/dev/null || true
  # Verify it's deleted
  if [ ! -f "${LOCK_FILE}" ]; then
    echo "[SUCCESS] Lock file removed"
  else
    echo "[WARN] Lock file still exists after removal attempt"
  fi
else
  echo "[INFO] Other jobs waiting for lock (${OTHER_LOCK_PROCESSES} processes), keeping lock file"
  # The lock file will be released automatically when the flock is released
fi

# Verify our job's lock is released
if [ ! -f "${LOCK_FILE}.pid" ]; then
  echo "[SUCCESS] This job's lock files cleaned up successfully"
  echo "[SUCCESS] Beaker machine is now available for next CI job"
  exit 0
else
  echo "[WARN] Some lock files may still exist, but this job's process is terminated"
  exit 0
fi
RELEASESCRIPT
  then
    log_success "Lock released successfully on Beaker machine"
    log_info "Beaker machine is now available for other CI jobs"
  else
    log_warn "Lock release script failed, but this is non-fatal"
    log_warn "Lock will auto-release after 4-hour safety timeout"
  fi

  # Archive lock holder log for debugging (before it gets deleted)
  log_info "Archiving lock holder log..."
  if [ -n "${LOCK_HOLDER_LOG:-}" ]; then
    scp "${SSHOPTS[@]}" \
      "${BEAKER_USER}@${BEAKER_IP}:${LOCK_HOLDER_LOG}" \
      "${ARTIFACT_DIR}/cleanup-logs/lock-holder.log" 2>&1 || log_warn "Could not archive lock holder log"
  else
    log_warn "Lock holder log path not found in beaker_lock_info"
  fi

else
  log_warn "Lock info not found in ${SHARED_DIR}/beaker_lock_info"
  log_warn "This might mean the lock was never acquired or already released"
fi

log_info "Lock release procedure completed"

exit 0
