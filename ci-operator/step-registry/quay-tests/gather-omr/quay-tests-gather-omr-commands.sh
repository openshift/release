#!/bin/bash

set -o nounset
set -o pipefail
# Do NOT set -e: gather steps must be best-effort, collect as much as possible

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "=== Gathering OMR diagnostics from EC2 instance ==="

# ── Locate the OMR EC2 hostname ──
if [[ ! -s "${SHARED_DIR}/OMR_HOST_NAME" ]]; then
    echo "No OMR_HOST_NAME found in SHARED_DIR, skipping gather"
    exit 0
fi
OMR_HOST_NAME="$(< "${SHARED_DIR}/OMR_HOST_NAME")"
echo "OMR host: ${OMR_HOST_NAME}"

# ── Extract the quaybuilder SSH key from terraform.tgz ──
if [[ ! -s "${SHARED_DIR}/terraform.tgz" ]]; then
    echo "No terraform.tgz found in SHARED_DIR, skipping gather"
    exit 0
fi

WORK_DIR=$(mktemp -d)
cd "${WORK_DIR}"
tar -xzf "${SHARED_DIR}/terraform.tgz" quaybuilder 2>/dev/null
if [[ ! -f quaybuilder ]]; then
    echo "quaybuilder SSH key not found inside terraform.tgz, skipping gather"
    rm -rf "${WORK_DIR}"
    exit 0
fi
chmod 600 quaybuilder
SSH_KEY="${WORK_DIR}/quaybuilder"

SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ConnectTimeout=30 -o ConnectionAttempts=3"

echo "Connecting as ${SSH_USER}@${OMR_HOST_NAME}"

# Helper: run a command on the OMR EC2 and save output to ARTIFACT_DIR
function omr_cmd() {
    local desc="$1"
    local artifact_name="$2"
    local cmd="$3"
    echo "  Collecting: ${desc}"
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${SSH_USER}@${OMR_HOST_NAME}" \
        "${cmd}" > "${ARTIFACT_DIR}/${artifact_name}" 2>&1 || true
}

# ── Container listing ──
omr_cmd "podman ps --all" "omr-podman-ps.txt" \
    "sudo podman ps -a 2>/dev/null || echo 'podman not available'" || true

# ── Container logs (most important for debugging) ──
omr_cmd "podman logs quay-app" "omr-quay-app.log" \
    "sudo podman logs quay-app 2>&1 || echo 'quay-app container not found'" || true

omr_cmd "podman logs quay-postgres" "omr-quay-postgres.log" \
    "sudo podman logs quay-postgres 2>&1 || echo 'quay-postgres container not found'" || true

omr_cmd "podman logs quay-redis" "omr-quay-redis.log" \
    "sudo podman logs quay-redis 2>&1 || echo 'quay-redis container not found'" || true

# ── System resource stats ──
omr_cmd "system resources (memory, disk, uptime)" "omr-system-resources.txt" \
    "free -m && echo '---' && df -m && echo '---' && uptime" || true

# ── Network listeners ──
omr_cmd "listening ports" "omr-listeners.txt" \
    "sudo ss -tlnp 2>/dev/null || echo 'ss not available'" || true

# ── Cleanup ──
rm -rf "${WORK_DIR}"

echo "=== OMR gather complete ==="
ls -la "${ARTIFACT_DIR}"/omr-* 2>/dev/null || echo "No artifacts collected"
