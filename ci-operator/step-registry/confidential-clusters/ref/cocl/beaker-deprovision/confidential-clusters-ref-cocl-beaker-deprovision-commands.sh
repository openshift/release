#!/bin/bash

# Beaker Deprovision Step - Cleanup all resources on Beaker machine
set -o nounset
set -o pipefail
# Note: Not setting -e to allow best-effort cleanup

# ============================================================================
# Prow CI Standard Environment Variables Check
# ============================================================================

if [ -z "${SHARED_DIR:-}" ]; then
  echo "[ERROR] SHARED_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

if [ -z "${ARTIFACT_DIR:-}" ]; then
  echo "[ERROR] ARTIFACT_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

echo "=========================================="
echo "Beaker Cleanup and Deprovision - Starting"
echo "=========================================="
echo "This script performs cleanup operations on Beaker machine"
echo "=========================================="
date

# ============================================================================
# Prow CI User Environment Setup
# ============================================================================

if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "[INFO] Creating user entry for UID $(id -u) in /etc/passwd"
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

# ============================================================================
# Global Variables and Configuration
# ============================================================================

# Cleanup status tracking
CLEANUP_STATUS=0
CLEANUP_FAILED=false

# Configurable options
DEPROVISION_TIMEOUT="${DEPROVISION_TIMEOUT:-600}"
CLEANUP_IMAGES="${CLEANUP_IMAGES:-true}"
RESTART_SERVICES="${RESTART_SERVICES:-true}"

# ============================================================================
# Helper Functions
# ============================================================================

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

log_info "Reading configuration..."

if [ -f "${SHARED_DIR}/beaker_info" ]; then
  source "${SHARED_DIR}/beaker_info"
  log_info "Beaker machine: ${BEAKER_IP}"
  log_info "Beaker user: ${BEAKER_USER}"
  log_info "Cluster name: ${KIND_CLUSTER_NAME:-kind}"
  log_info "Container runtime: ${CONTAINER_RUNTIME:-docker}"
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
  CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
fi

# ============================================================================
# SSH Key Setup
# ============================================================================

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

# ============================================================================
# SSH Options Configuration
# ============================================================================

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
# Pre-Cleanup: Collect System State
# ============================================================================

log_info "Collecting pre-cleanup system state..."

mkdir -p "${ARTIFACT_DIR}/cleanup-logs/archived-logs"

# Collect system state before cleanup
ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s << 'EOF' > "${ARTIFACT_DIR}/cleanup-logs/pre-cleanup-state.log" 2>&1 || true

echo "=========================================="
echo "Pre-Cleanup System State"
echo "=========================================="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo ""

echo "--- Kind Clusters ---"
kind get clusters 2>&1 || echo "No clusters or kind not available"
echo ""

echo "--- Docker Containers ---"
docker ps -a 2>&1 || echo "Docker not available"
echo ""

echo "--- Podman Containers ---"
podman ps -a 2>&1 || echo "Podman not available"
echo ""

echo "--- Docker Images ---"
docker images 2>&1 || echo "Docker not available"
echo ""

echo "--- Podman Images ---"
podman images 2>&1 || echo "Podman not available"
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

# ============================================================================
# Archive Important Logs
# ============================================================================

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

# ============================================================================
# Execute Cleanup on Beaker Machine
# ============================================================================

log_info "Executing cleanup operations on Beaker machine..."

if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${KIND_CLUSTER_NAME}" "${CONTAINER_RUNTIME}" "${CLEANUP_IMAGES}" "${RESTART_SERVICES}" << 'EOF'

set -x  # Enable command tracing for debugging

KIND_CLUSTER_NAME="$1"
CONTAINER_RUNTIME="$2"
CLEANUP_IMAGES="$3"
RESTART_SERVICES="$4"

echo "=========================================="
echo "Running on Beaker machine: $(hostname)"
echo "Date: $(date)"
echo "Cluster to delete: ${KIND_CLUSTER_NAME}"
echo "Container runtime: ${CONTAINER_RUNTIME}"
echo "Cleanup images: ${CLEANUP_IMAGES}"
echo "Restart services: ${RESTART_SERVICES}"
echo "=========================================="

# Create cleanup log directory
mkdir -p /tmp/cleanup-logs
exec > >(tee -a /tmp/cleanup-logs/cleanup.log)
exec 2>&1

CLEANUP_ERRORS=0

# ============================================================================
# 1. Delete Kind Cluster
# ============================================================================
echo ""
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

# ============================================================================
# 2. Clean Up Container Images
# ============================================================================
echo ""
echo "--- Step 2: Cleaning up container images ---"

if [ "${CLEANUP_IMAGES}" == "true" ]; then
    # Clean up Docker images
    if command -v docker &> /dev/null; then
        echo "[INFO] Cleaning up Docker images..."

        # Remove localhost:5000/* images (local registry)
        docker images "localhost:5000/*" -q | xargs -r docker rmi -f 2>&1 || echo "[WARN] Some Docker images could not be removed"

        # Remove cocl-operator related images
        docker images | grep -i cocl | awk '{print $3}' | xargs -r docker rmi -f 2>&1 || echo "[WARN] Some cocl images could not be removed"

        # Remove dangling images
        docker image prune -f 2>&1 || echo "[WARN] Docker image prune failed"

        echo "[SUCCESS] Docker images cleaned up"
    else
        echo "[WARN] docker command not found"
    fi

    # Clean up Podman images
    if command -v podman &> /dev/null; then
        echo "[INFO] Cleaning up Podman images..."

        # Remove localhost:5000/* images (local registry)
        podman images "localhost:5000/*" -q | xargs -r podman rmi -f 2>&1 || echo "[WARN] Some Podman images could not be removed"

        # Remove cocl-operator related images
        podman images | grep -i cocl | awk '{print $3}' | xargs -r podman rmi -f 2>&1 || echo "[WARN] Some cocl images could not be removed"

        # Remove dangling images
        podman image prune -f 2>&1 || echo "[WARN] Podman image prune failed"

        echo "[SUCCESS] Podman images cleaned up"
    else
        echo "[WARN] podman command not found"
    fi
else
    echo "[INFO] Image cleanup skipped (CLEANUP_IMAGES=false)"
fi

# ============================================================================
# 3. Remove Temporary Files and Directories
# ============================================================================
echo ""
echo "--- Step 3: Removing temporary files ---"

# Remove kind-related temporary directories
echo "[INFO] Removing kind temporary directories..."
rm -rf /tmp/kind-deployment-logs 2>&1 || echo "[WARN] Could not remove /tmp/kind-deployment-logs"
rm -rf /tmp/kind-cluster-logs 2>&1 || echo "[WARN] Could not remove /tmp/kind-cluster-logs"

# Remove operator-related temporary directories
echo "[INFO] Removing operator temporary directories..."
rm -rf /tmp/operator-install-logs 2>&1 || echo "[WARN] Could not remove /tmp/operator-install-logs"

# Remove e2e-test temporary directories
echo "[INFO] Removing e2e-test temporary directories..."
rm -rf /tmp/e2e-test-logs 2>&1 || echo "[WARN] Could not remove /tmp/e2e-test-logs"
rm -rf /tmp/e2e-test-results 2>&1 || echo "[WARN] Could not remove /tmp/e2e-test-results"

# Remove cleanup logs (will be recreated if needed)
rm -rf /tmp/cleanup-logs 2>&1 || echo "[WARN] Could not remove /tmp/cleanup-logs"

echo "[SUCCESS] Temporary files cleaned up"

# ============================================================================
# 4. Clean Up cocl-operator Working Directories
# ============================================================================
echo ""
echo "--- Step 4: Cleaning up cocl-operator directories ---"

# Remove cocl-operator working directory from provision step
if [ -d "${HOME}/cocl-operator-kind-setup" ]; then
    echo "[INFO] Removing ${HOME}/cocl-operator-kind-setup..."
    rm -rf "${HOME}/cocl-operator-kind-setup" 2>&1 || echo "[WARN] Could not remove cocl-operator-kind-setup"
fi

# Remove cocl-operator working directory from install step
if [ -d "${HOME}/cocl-operator" ]; then
    echo "[INFO] Removing ${HOME}/cocl-operator..."
    rm -rf "${HOME}/cocl-operator" 2>&1 || echo "[WARN] Could not remove cocl-operator"
fi

echo "[SUCCESS] cocl-operator directories cleaned up"

# ============================================================================
# 5. Clean Up Libvirt VMs and Resources
# ============================================================================
echo ""
echo "--- Step 5: Cleaning up Libvirt VMs and resources ---"

if command -v virsh &> /dev/null; then
    echo "[INFO] Libvirt tools available, proceeding with VM cleanup..."

    # List all VMs
    echo "[INFO] Listing all VMs..."
    sudo virsh list --all 2>&1 || echo "[WARN] Could not list VMs"

    # Clean up VMs matching E2E test patterns
    for VM_PATTERN in "existing-trustee" "fcos" "cocl"; do
        echo "[INFO] Checking for VMs matching pattern: ${VM_PATTERN}"

        # Get VMs matching pattern
        VM_LIST=$(sudo virsh list --all --name 2>/dev/null | grep -i "${VM_PATTERN}" || true)

        if [ -n "${VM_LIST}" ]; then
            echo "${VM_LIST}" | while read -r VM_NAME; do
                if [ -n "${VM_NAME}" ]; then
                    echo "[INFO] Processing VM: ${VM_NAME}"

                    # Stop VM if running
                    VM_STATE=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null || echo "unknown")
                    if [ "${VM_STATE}" == "running" ]; then
                        echo "[INFO] Stopping VM ${VM_NAME}..."
                        sudo virsh destroy "${VM_NAME}" 2>&1 || echo "[WARN] Could not destroy VM ${VM_NAME}"
                    else
                        echo "[INFO] VM ${VM_NAME} is ${VM_STATE}, not running"
                    fi

                    # Undefine VM
                    echo "[INFO] Undefining VM ${VM_NAME}..."
                    sudo virsh undefine "${VM_NAME}" --remove-all-storage 2>&1 || \
                        sudo virsh undefine "${VM_NAME}" 2>&1 || \
                        echo "[WARN] Could not undefine VM ${VM_NAME}"

                    echo "[SUCCESS] VM ${VM_NAME} cleaned up"
                fi
            done
        else
            echo "[INFO] No VMs found matching pattern: ${VM_PATTERN}"
        fi
    done

    # Clean up VM disk images in libvirt directory
    echo "[INFO] Cleaning up VM disk images..."
    LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"

    if [ -d "${LIBVIRT_IMAGE_DIR}" ]; then
        # Remove FCOS QEMU images
        sudo rm -f "${LIBVIRT_IMAGE_DIR}/fcos-qemu*.qcow2" 2>&1 || echo "[WARN] Could not remove FCOS QEMU images"
        sudo rm -f "${LIBVIRT_IMAGE_DIR}/fcos*.qcow2" 2>&1 || echo "[WARN] Could not remove FCOS images"

        # Remove VM console logs
        sudo rm -f "${LIBVIRT_IMAGE_DIR}/existing-trustee*.log" 2>&1 || echo "[WARN] Could not remove VM console logs"
        sudo rm -f "${LIBVIRT_IMAGE_DIR}/*.log" 2>&1 || echo "[WARN] Could not remove log files"

        echo "[SUCCESS] VM disk images cleaned up"
    else
        echo "[INFO] Libvirt images directory not found, skipping"
    fi

    # Clean up libvirt networks (if any created by tests)
    echo "[INFO] Checking for test-created libvirt networks..."
    for NET_PATTERN in "cocl" "e2e-test" "fcos"; do
        NET_LIST=$(sudo virsh net-list --all --name 2>/dev/null | grep -i "${NET_PATTERN}" || true)
        if [ -n "${NET_LIST}" ]; then
            echo "${NET_LIST}" | while read -r NET_NAME; do
                if [ -n "${NET_NAME}" ] && [ "${NET_NAME}" != "default" ]; then
                    echo "[INFO] Destroying network ${NET_NAME}..."
                    sudo virsh net-destroy "${NET_NAME}" 2>&1 || echo "[WARN] Could not destroy network ${NET_NAME}"
                    sudo virsh net-undefine "${NET_NAME}" 2>&1 || echo "[WARN] Could not undefine network ${NET_NAME}"
                fi
            done
        fi
    done

    echo "[SUCCESS] Libvirt VMs and resources cleaned up"
else
    echo "[INFO] Libvirt tools not available, skipping VM cleanup"
fi

# ============================================================================
# 6. Clean Up FCOS Container Images and Build Artifacts
# ============================================================================
echo ""
echo "--- Step 6: Cleaning up FCOS images and build artifacts ---"

if [ "${CLEANUP_IMAGES}" == "true" ]; then
    # Clean up FCOS container images from Podman
    if command -v podman &> /dev/null; then
        echo "[INFO] Cleaning up FCOS container images..."

        # Remove FCOS images from quay.io
        sudo podman images | grep -i "fedora-coreos\|fcos" | awk '{print $3}' | xargs -r sudo podman rmi -f 2>&1 || \
            echo "[WARN] Could not remove all FCOS images"

        # Remove trusted-execution-clusters images
        sudo podman images | grep "trusted-execution-clusters" | awk '{print $3}' | xargs -r sudo podman rmi -f 2>&1 || \
            echo "[WARN] Could not remove trusted-execution-clusters images"

        echo "[SUCCESS] FCOS container images cleaned up"
    fi

    # Clean up build artifacts
    echo "[INFO] Cleaning up build artifacts..."

    # Remove investigations repository
    if [ -d "${HOME}/investigations" ]; then
        echo "[INFO] Removing investigations repository..."
        rm -rf "${HOME}/investigations" 2>&1 || echo "[WARN] Could not remove investigations directory"
    fi

    # Remove osbuild cache and artifacts
    echo "[INFO] Cleaning up osbuild artifacts..."
    rm -rf "${HOME}/.cache/osbuild" 2>&1 || echo "[WARN] Could not remove osbuild cache"
    sudo rm -rf /var/cache/osbuild 2>&1 || echo "[WARN] Could not remove system osbuild cache"

    # Remove coreos OCI archives
    if [ -d "${HOME}/investigations/coreos" ]; then
        echo "[INFO] Removing coreos OCI archives..."
        rm -rf "${HOME}/investigations/coreos" 2>&1 || echo "[WARN] Could not remove coreos directory"
    fi

    echo "[SUCCESS] Build artifacts cleaned up"
else
    echo "[INFO] FCOS image and artifact cleanup skipped (CLEANUP_IMAGES=false)"
fi

# ============================================================================
# 7. Clean Up E2E Test Logs and SSH Keys
# ============================================================================
echo ""
echo "--- Step 7: Cleaning up E2E test logs and SSH keys ---"

# Remove KBS logs
echo "[INFO] Removing KBS log directories..."
sudo rm -rf /var/log/kbs_logs_* 2>&1 || echo "[WARN] Could not remove KBS logs"

# Remove E2E test logs
echo "[INFO] Removing E2E test logs..."
rm -rf /tmp/e2e-test-logs 2>&1 || echo "[WARN] Could not remove E2E test logs"

# Remove SSH keys created for VM access
echo "[INFO] Cleaning up SSH keys created for VM access..."
if [ -f "/root/.ssh/id_ed25519" ]; then
    sudo rm -f /root/.ssh/id_ed25519 2>&1 || echo "[WARN] Could not remove VM SSH private key"
fi
if [ -f "/root/.ssh/id_ed25519.pub" ]; then
    sudo rm -f /root/.ssh/id_ed25519.pub 2>&1 || echo "[WARN] Could not remove VM SSH public key"
fi

echo "[SUCCESS] E2E test logs and SSH keys cleaned up"

# ============================================================================
# 8. Restart Container Runtime Services (Optional)
# ============================================================================
echo ""
echo "--- Step 8: Restarting container runtime services ---"

if [ "${RESTART_SERVICES}" == "true" ]; then
    # Restart Docker
    if command -v docker &> /dev/null; then
        echo "[INFO] Restarting Docker service..."
        if sudo systemctl restart docker; then
            echo "[SUCCESS] Docker service restarted"
        else
            echo "[ERROR] Failed to restart Docker service"
            ((CLEANUP_ERRORS++))
        fi
    fi

    # Restart Podman socket
    if command -v podman &> /dev/null; then
        echo "[INFO] Restarting Podman socket..."
        if sudo systemctl restart podman.socket; then
            echo "[SUCCESS] Podman socket restarted"
        else
            echo "[ERROR] Failed to restart Podman socket"
            ((CLEANUP_ERRORS++))
        fi
    fi

    # Restart Libvirt service
    if command -v virsh &> /dev/null; then
        echo "[INFO] Restarting Libvirt service..."
        if sudo systemctl restart libvirtd; then
            echo "[SUCCESS] Libvirt service restarted"
        else
            echo "[WARN] Failed to restart Libvirt service (non-critical)"
        fi
    fi
else
    echo "[INFO] Service restart skipped (RESTART_SERVICES=false)"
fi

# ============================================================================
# Cleanup Summary
# ============================================================================
echo ""
echo "=========================================="
echo "Cleanup Summary"
echo "=========================================="
echo "Cleanup errors encountered: ${CLEANUP_ERRORS}"
echo ""

echo "--- Final Disk Usage ---"
df -h
echo ""

echo "--- Remaining Containers (Docker) ---"
docker ps -a 2>&1 || echo "Docker not available"
echo ""

echo "--- Remaining Containers (Podman) ---"
podman ps -a 2>&1 || echo "Podman not available"
echo ""

echo "--- Remaining Kind Clusters ---"
kind get clusters 2>&1 || echo "No clusters or kind not available"
echo ""

echo "--- Remaining VMs (Libvirt) ---"
if command -v virsh &> /dev/null; then
    sudo virsh list --all 2>&1 || echo "Could not list VMs"
else
    echo "Libvirt not available"
fi
echo ""

echo "--- Remaining VM Disk Images ---"
if [ -d "/var/lib/libvirt/images" ]; then
    ls -lh /var/lib/libvirt/images/*.qcow2 2>&1 || echo "No qcow2 images found"
else
    echo "Libvirt images directory not found"
fi
echo ""

echo "--- Remaining Test Artifacts ---"
ls -ld "${HOME}/investigations" 2>&1 || echo "No investigations directory"
ls -ld /var/log/kbs_logs_* 2>&1 || echo "No KBS log directories"
echo ""

echo "=========================================="
echo "Cleanup completed with ${CLEANUP_ERRORS} errors"
echo "=========================================="
date

# Exit with success even if there were minor errors (best-effort cleanup)
exit 0

EOF
then
  log_error "Cleanup script execution failed"
  CLEANUP_FAILED=true
  CLEANUP_STATUS=1
else
  log_success "Cleanup script executed successfully"
fi

# ============================================================================
# Collect Cleanup Logs
# ============================================================================

log_info "Collecting cleanup logs..."

scp "${SSHOPTS[@]}" \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/cleanup-logs/cleanup.log" \
  "${ARTIFACT_DIR}/cleanup-logs/cleanup-execution.log" 2>&1 || log_warn "Could not collect cleanup execution log"

# ============================================================================
# Post-Cleanup: Collect Final System State
# ============================================================================

log_info "Collecting post-cleanup system state..."

ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s << 'EOF' > "${ARTIFACT_DIR}/cleanup-logs/post-cleanup-state.log" 2>&1 || true

echo "=========================================="
echo "Post-Cleanup System State"
echo "=========================================="
echo "Date: $(date)"
echo ""

echo "--- Kind Clusters (should be empty) ---"
kind get clusters 2>&1 || echo "No clusters or kind not available"
echo ""

echo "--- Docker Containers (should be minimal) ---"
docker ps -a 2>&1 || echo "Docker not available"
echo ""

echo "--- Podman Containers (should be minimal) ---"
podman ps -a 2>&1 || echo "Podman not available"
echo ""

echo "--- Docker Images ---"
docker images 2>&1 || echo "Docker not available"
echo ""

echo "--- Podman Images ---"
podman images 2>&1 || echo "Podman not available"
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

# ============================================================================
# Final Status
# ============================================================================

if $CLEANUP_FAILED; then
  echo ""
  echo "=========================================="
  echo "Beaker Cleanup - COMPLETED WITH ERRORS"
  echo "=========================================="
  echo "Some cleanup operations failed"
  echo "Check logs in ${ARTIFACT_DIR}/cleanup-logs/"
  echo "=========================================="
  date
  exit ${CLEANUP_STATUS}
fi

echo ""
echo "=========================================="
echo "Beaker Cleanup - Completed Successfully"
echo "=========================================="
echo "Beaker Machine: ${BEAKER_IP}"
echo "Cluster Deleted: ${KIND_CLUSTER_NAME}"
echo "Images Cleaned: ${CLEANUP_IMAGES}"
echo "Services Restarted: ${RESTART_SERVICES}"
echo ""
echo "Cleanup Logs: ${ARTIFACT_DIR}/cleanup-logs/"
echo "Archived Logs: ${ARTIFACT_DIR}/cleanup-logs/archived-logs/"
echo "=========================================="
date

exit 0
