#!/bin/bash
# ---------------------------------------------------------------------------
# OPP disk-layout diagnostic step
#
# Captures disk layout information from a worker node to help diagnose
# why the RHCOS root filesystem may not be expanding to fill the
# configured EBS volume.  This is a best-effort diagnostic step — it
# must never fail the chain.
# ---------------------------------------------------------------------------

set -uo pipefail

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

DIAG_DIR="${ARTIFACT_DIR}/disk-diag"
mkdir -p "${DIAG_DIR}"

echo "=== OPP Disk Diagnostics ==="

# Pick the first Ready worker node
WORKER=""
WORKER=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true

if [[ -z "${WORKER}" ]]; then
    echo "WARNING: No worker node found — skipping disk diagnostics."
    exit 0
fi

echo "Target worker node: ${WORKER}"

# Helper: run a command on the node via oc debug, capture output.
# Always returns 0 so a single failed command does not abort the step.
run_on_node() {
    local label="$1"; shift
    local outfile="${DIAG_DIR}/${label}.txt"
    echo "--- Collecting: ${label} ---"
    if oc debug "node/${WORKER}" --quiet -- chroot /host "$@" \
        > "${outfile}" 2>&1; then
        echo "  -> saved to ${outfile}"
    else
        echo "  -> command failed (non-fatal), partial output in ${outfile}"
    fi
    return 0
}

# 1. Block device layout
run_on_node "lsblk" lsblk --fs --output NAME,FSTYPE,SIZE,MOUNTPOINT,LABEL

# 2. Filesystem usage
run_on_node "df" df -h

# 3. ignition-ostree-growfs.service status
run_on_node "growfs-status" \
    systemctl status ignition-ostree-growfs.service --no-pager --full

# 4. ignition-ostree-growfs.service journal
run_on_node "growfs-journal" \
    journalctl -u ignition-ostree-growfs.service --no-pager -l

# 5. Disk usage of key directories
for dir in /var/lib/containers /var/log/pods /var/lib/kubelet; do
    safe_name="du-$(echo "${dir}" | tr '/' '-' | sed 's/^-//')"
    run_on_node "${safe_name}" du -sh "${dir}"
done

# 6. KubeletConfiguration
echo "--- Collecting: kubeletconfig ---"
oc get kubeletconfigs -o yaml > "${DIAG_DIR}/kubeletconfig.yaml" 2>&1 || true
echo "  -> saved to ${DIAG_DIR}/kubeletconfig.yaml"

echo "=== Disk diagnostics complete — artifacts in ${DIAG_DIR} ==="

# Always exit 0 — this is a diagnostic step and must not fail the chain
exit 0
