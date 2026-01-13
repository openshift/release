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
podman ps -a 2>&1 || echo "Podman not available"
echo ""

echo "--- Container Images ---"
docker images 2>&1 || echo "Docker not available"
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

echo "--- SSH Agent Processes ---"
pgrep -u $(whoami) -a ssh-agent 2>&1 || echo "No ssh-agent processes found"
echo "Total ssh-agent count: $(pgrep -u $(whoami) ssh-agent 2>/dev/null | wc -l)"
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

scp "${SSHOPTS[@]}" -r \
  "${BEAKER_USER}@${BEAKER_IP}:/tmp/e2e-test-logs/*" \
  "${ARTIFACT_DIR}/cleanup-logs/archived-logs/" 2>&1 || log_warn "Could not archive E2E test logs"

scp "${SSHOPTS[@]}" -r \
  "${BEAKER_USER}@${BEAKER_IP}:/var/log/kbs_logs_*" \
  "${ARTIFACT_DIR}/cleanup-logs/archived-logs/" 2>&1 || log_warn "Could not archive KBS logs"

log_success "Log archiving completed (best effort)"

log_info "Executing cleanup operations on Beaker machine..."

if ! ssh "${SSHOPTS[@]}" "${BEAKER_USER}@${BEAKER_IP}" bash -s -- \
  "${KIND_CLUSTER_NAME}" "${CONTAINER_RUNTIME}" "${CLEANUP_IMAGES}" "${RESTART_SERVICES}" << 'EOF'
set -x  # Enable command tracing for debugging

KIND_CLUSTER_NAME="$1"
CONTAINER_RUNTIME="$2"
CLEANUP_IMAGES="$3"
RESTART_SERVICES="$4"

echo "Running on Beaker machine: $(hostname)"
echo "Date: $(date)"
echo "Cluster to delete: ${KIND_CLUSTER_NAME}"
echo "Container runtime: ${CONTAINER_RUNTIME}"
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

echo "--- Step 2: Cleaning up Kind-related containers ---"

if [ "${CLEANUP_IMAGES}" == "true" ]; then
    # Clean up only Kind-related containers
    if command -v docker &> /dev/null; then
        echo "[INFO] Cleaning up Kind-related Docker containers and volumes..."
        # Remove containers with kind label
        docker ps -a --filter "label=io.x-k8s.kind.cluster" -q | xargs -r docker rm -f 2>&1 || echo "[INFO] No Kind containers to remove"
        # Remove volumes created by Kind
        docker volume ls --filter "label=io.x-k8s.kind.cluster" -q | xargs -r docker volume rm 2>&1 || echo "[INFO] No Kind volumes to remove"
        # Note: Removed 'docker system prune' as it can corrupt containerd state
        # Kind cleanup above is sufficient for test cleanup
        echo "[SUCCESS] Kind-related Docker resources cleaned up"
    fi

    if command -v podman &> /dev/null; then
        echo "[INFO] Cleaning up Kind-related Podman containers..."
        sudo podman ps -a --filter "label=io.x-k8s.kind.cluster" -q | xargs -r sudo podman rm -f 2>&1 || echo "[INFO] No Kind containers to remove"
        sudo podman volume ls --filter "label=io.x-k8s.kind.cluster" -q | xargs -r sudo podman volume rm 2>&1 || echo "[INFO] No Kind volumes to remove"
        echo "[SUCCESS] Kind-related Podman resources cleaned up"
    fi
else
    echo "[INFO] Container resource cleanup skipped"
fi

echo "--- Step 3: Cleaning up Kind network resources ---"

# Clean up only Kind-created networks, not docker0 or system networks
if command -v docker &> /dev/null; then
    echo "[INFO] Cleaning up Kind-created Docker networks..."
    docker network ls --filter "label=io.x-k8s.kind.cluster" -q | xargs -r docker network rm 2>&1 || echo "[INFO] No Kind networks to remove"
    # Also remove the 'kind' network if it exists
    docker network rm kind 2>&1 || echo "[INFO] Kind network not found"
    echo "[SUCCESS] Kind networks cleaned up"
fi

# Clean up only test-related Libvirt networks, keep default
if command -v virsh &> /dev/null; then
    echo "[INFO] Cleaning up test-related Libvirt networks..."
    for net in $(sudo virsh net-list --all --name 2>/dev/null | grep -E "kind|test" || true); do
        if [ -n "$net" ]; then
            sudo virsh net-destroy "$net" 2>&1 || echo "[INFO] Network $net not running"
            sudo virsh net-undefine "$net" 2>&1 || echo "[INFO] Network $net not defined"
        fi
    done
    echo "[SUCCESS] Test Libvirt networks cleaned up"
else
    echo "[INFO] Libvirt not available, skipping network cleanup"
fi

echo "--- Step 4: Skipping container runtime data directories ---"

echo "[INFO] NOT deleting /var/lib/docker, /var/lib/containerd, or /var/lib/containers"
echo "[INFO] These directories must be preserved to keep Docker/containerd functional"
echo "[INFO] Only test-specific containers and images are cleaned up in previous steps"

echo "[SUCCESS] Container runtime data directories preserved"

echo "--- Step 5: Removing temporary files ---"

rm -rf /tmp/kind-* 2>&1 || echo "[WARN] Could not remove kind temp directories"
rm -rf /tmp/operator-* 2>&1 || echo "[WARN] Could not remove operator temp directories"
rm -rf /tmp/e2e-test-* 2>&1 || echo "[WARN] Could not remove e2e-test temp directories"

echo "[SUCCESS] Temporary files cleaned up"

echo "--- Step 6: Cleaning up operator working directories ---"

if [ -d "${HOME}/operator-kind-setup" ]; then
    echo "[INFO] Removing operator-kind-setup directory..."
    rm -rf "${HOME}/operator-kind-setup" 2>&1 || echo "[WARN] Could not remove directory"
fi

if [ -d "${HOME}/cocl-operator-kind-setup" ]; then
    echo "[INFO] Removing cocl-operator-kind-setup directory..."
    rm -rf "${HOME}/cocl-operator-kind-setup" 2>&1 || echo "[WARN] Could not remove directory"
fi

if [ -d "${HOME}/cocl-operator" ]; then
    echo "[INFO] Removing cocl-operator directory..."
    rm -rf "${HOME}/cocl-operator" 2>&1 || echo "[WARN] Could not remove directory"
fi

echo "[SUCCESS] Operator working directories cleaned up"

echo "--- Step 7: Cleaning up Libvirt VMs and resources ---"

if command -v virsh &> /dev/null; then
    # Clean up VMs matching test patterns
    for VM_PATTERN in "existing-trustee" "fcos" "cocl"; do
        VM_LIST=$(sudo virsh list --all --name 2>/dev/null | grep -i "${VM_PATTERN}" || true)
        if [ -n "${VM_LIST}" ]; then
            echo "${VM_LIST}" | while read -r VM_NAME; do
                if [ -n "${VM_NAME}" ]; then
                    # Stop and undefine VM
                    sudo virsh destroy "${VM_NAME}" 2>&1 || echo "[WARN] Could not destroy VM"
                    sudo virsh undefine "${VM_NAME}" --remove-all-storage 2>&1 || \
                        sudo virsh undefine "${VM_NAME}" 2>&1 || \
                        echo "[WARN] Could not undefine VM"
                fi
            done
        fi
    done

    # Clean up VM disk images
    LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"
    if [ -d "${LIBVIRT_IMAGE_DIR}" ]; then
        sudo rm -f "${LIBVIRT_IMAGE_DIR}"/fcos*.qcow2 2>&1 || echo "[WARN] Could not remove FCOS images"
        sudo rm -f "${LIBVIRT_IMAGE_DIR}"/*.log 2>&1 || echo "[WARN] Could not remove log files"
    fi
else
    echo "[INFO] Libvirt tools not available, skipping VM cleanup"
fi

echo "[SUCCESS] Libvirt VMs and resources cleaned up"

echo "--- Step 8: Cleaning up test-specific build artifacts ---"

# Clean build artifacts but not container images (images already cleaned in Step 2)
echo "[INFO] Cleaning build artifacts..."
rm -rf "${HOME}/investigations" 2>&1 || echo "[WARN] Could not remove investigations directory"
rm -rf "${HOME}/.cache/osbuild" 2>&1 || echo "[WARN] Could not remove osbuild cache"
sudo rm -rf /var/cache/osbuild 2>&1 || echo "[WARN] Could not remove system osbuild cache"

echo "[SUCCESS] Build artifacts cleaned up"

echo "--- Step 9: Cleaning up test logs and SSH keys ---"

sudo rm -rf /var/log/kbs_logs_* 2>&1 || echo "[WARN] Could not remove KBS logs"
rm -rf /tmp/e2e-test-logs 2>&1 || echo "[WARN] Could not remove E2E test logs"

# Remove SSH keys
if [ -f "/root/.ssh/id_ed25519" ]; then
    sudo rm -f /root/.ssh/id_ed25519 2>&1 || echo "[WARN] Could not remove VM SSH private key"
fi
if [ -f "/root/.ssh/id_ed25519.pub" ]; then
    sudo rm -f /root/.ssh/id_ed25519.pub 2>&1 || echo "[WARN] Could not remove VM SSH public key"
fi

# Kill all ssh-agent processes to prevent accumulation
echo "[INFO] Cleaning up ssh-agent processes..."
AGENT_COUNT=$(pgrep -u $(whoami) ssh-agent 2>/dev/null | wc -l)
if [ "$AGENT_COUNT" -gt 0 ]; then
    echo "[INFO] Found ${AGENT_COUNT} ssh-agent process(es), terminating..."
    sudo pkill -u $(whoami) ssh-agent 2>&1 || echo "[WARN] Could not kill some ssh-agent processes"
    sleep 1
    REMAINING=$(pgrep -u $(whoami) ssh-agent 2>/dev/null | wc -l)
    if [ "$REMAINING" -eq 0 ]; then
        echo "[SUCCESS] All ssh-agent processes terminated"
    else
        echo "[WARN] ${REMAINING} ssh-agent process(es) still running"
    fi
else
    echo "[INFO] No ssh-agent processes found"
fi

echo "[SUCCESS] Test logs, SSH keys, and ssh-agent cleaned up"

echo "--- Step 10: Reinitializing Docker and containerd ---"

# Ensure containerd directory structure exists and restart Docker
if command -v docker &> /dev/null; then
    echo "[INFO] Ensuring containerd directories exist with correct permissions..."
    sudo mkdir -p /var/lib/containerd/io.containerd.content.v1.content/ingest
    sudo mkdir -p /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots
    sudo mkdir -p /var/lib/containerd/tmpmounts
    sudo chmod -R 755 /var/lib/containerd
    echo "[SUCCESS] Containerd directories created"

    echo "[INFO] Restarting Docker service to reinitialize containerd..."
    if sudo systemctl restart docker 2>&1; then
        echo "[SUCCESS] Docker service restarted"
        # Wait for Docker to fully initialize
        sleep 10
        if docker info > /dev/null 2>&1; then
            echo "[SUCCESS] Docker daemon is responsive"
        else
            echo "[WARN] Docker daemon is not responsive after restart, this may indicate a problem"
        fi
    else
        echo "[ERROR] Failed to restart Docker service"
    fi
fi

if command -v virsh &> /dev/null; then
    echo "[INFO] Checking Libvirt service status..."
    if sudo systemctl is-active --quiet libvirtd; then
        echo "[SUCCESS] Libvirt service is running"
    else
        echo "[INFO] Libvirt service is not running"
    fi
fi

echo "--- Step 11: Verifying clean state ---"

# Verification checks
echo "[INFO] Checking remaining containers..."
DOCKER_CONTAINERS=$(docker ps -aq 2>/dev/null | wc -l)
PODMAN_CONTAINERS=$(sudo podman ps -aq 2>/dev/null | wc -l)
VM_COUNT=$(sudo virsh list --all --name 2>/dev/null | grep -v "^$" | wc -l)

echo "Docker containers: $DOCKER_CONTAINERS"
echo "Podman containers: $PODMAN_CONTAINERS"
echo "VMs: $VM_COUNT"

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

echo "--- Podman Containers (should be minimal) ---"
podman ps -a 2>&1 || echo "Podman not available"
echo ""

echo "--- Container Images ---"
docker images 2>&1 || echo "Docker not available"
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

exit 0