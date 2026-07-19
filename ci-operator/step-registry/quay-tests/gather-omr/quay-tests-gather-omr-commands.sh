#!/bin/bash

set -o nounset
set -o pipefail
# Do NOT set -e: gather steps must be best-effort, collect as much as possible

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "=== Gathering OMR diagnostics from bastion host ==="

# Locate bastion address
if [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
    BASTION_IP="$(< "${SHARED_DIR}/bastion_public_address")"
elif [[ -s "${SHARED_DIR}/bastion_private_address" ]]; then
    BASTION_IP="$(< "${SHARED_DIR}/bastion_private_address")"
else
    echo "No bastion address found in SHARED_DIR, skipping gather"
    exit 0
fi

if [[ ! -s "${SHARED_DIR}/bastion_ssh_user" ]]; then
    echo "No bastion_ssh_user found, skipping gather"
    exit 0
fi

BASTION_SSH_USER="$(< "${SHARED_DIR}/bastion_ssh_user")"
SSH_KEY="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ConnectTimeout=30 -o ConnectionAttempts=3"

echo "Bastion: ${BASTION_SSH_USER}@${BASTION_IP}"

# Helper: run a command on the bastion and save output to ARTIFACT_DIR
function bastion_cmd() {
    local desc="$1"
    local artifact_name="$2"
    local cmd="$3"
    echo "  Collecting: ${desc}"
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "${BASTION_SSH_USER}@${BASTION_IP}" \
        "${cmd}" > "${ARTIFACT_DIR}/${artifact_name}" 2>&1 || true
}

# ── Quay service status (systemd, if present) ──
bastion_cmd "systemctl status quay*" "omr-systemctl-status.txt" \
    "sudo systemctl status 'quay*' --no-pager 2>/dev/null || echo 'No quay systemd units found'"

bastion_cmd "journalctl quay" "omr-journalctl-quay.txt" \
    "sudo journalctl -u 'quay*' --no-pager -n 500 2>/dev/null || echo 'No quay journal entries'"

# ── Container listing ──
bastion_cmd "podman ps --all" "omr-podman-ps.txt" \
    "sudo podman ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || echo 'podman not available'"

# ── Container logs ──
for cname in quay-app quay-postgres quay-redis; do
    bastion_cmd "podman logs ${cname}" "omr-${cname}.log" \
        "sudo podman logs --tail 2000 ${cname} 2>&1 || echo '${cname} container not found'"
done

# ── Host resource usage ──
bastion_cmd "disk usage (df -h)" "omr-disk-usage.txt" \
    "df -h"

bastion_cmd "quay data dir size" "omr-quay-dir-size.txt" \
    "sudo du -sh /var/lib/quay 2>/dev/null || echo '/var/lib/quay not found'"

bastion_cmd "memory usage" "omr-memory.txt" \
    "free -h"

bastion_cmd "network listeners" "omr-listeners.txt" \
    "sudo ss -lntp 2>/dev/null || sudo netstat -lntp 2>/dev/null || echo 'ss/netstat not available'"

# ── Health check ──
OMR_HOST_NAME=""
if [[ -s "${SHARED_DIR}/OMR_HOST_NAME" ]]; then
    OMR_HOST_NAME="$(< "${SHARED_DIR}/OMR_HOST_NAME")"
fi

if [[ -n "${OMR_HOST_NAME}" ]]; then
    bastion_cmd "OMR health check (localhost)" "omr-health-check.txt" \
        "curl -sk --connect-timeout 10 https://localhost:8443/health/instance 2>&1 || echo 'Health check failed'"

    bastion_cmd "OMR v2 API check" "omr-api-check.txt" \
        "curl -sk --connect-timeout 10 https://localhost:8443/api/v1/superuser/registrystatus 2>&1 || echo 'API check failed'"
else
    echo "  Skipping health check: OMR_HOST_NAME not set"
fi

echo "=== OMR gather complete ==="
ls -la "${ARTIFACT_DIR}"/omr-* 2>/dev/null || echo "No artifacts collected"
