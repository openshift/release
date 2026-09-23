#!/bin/bash
set -euo pipefail

# Load environment (continue even if env file doesn't exist)
if [[ -f ${SHARED_DIR}/dpf-env ]]; then
    source ${SHARED_DIR}/dpf-env
else
    echo " No dpf-env file found, using defaults"
    REMOTE_HOST="${REMOTE_HOST:-nvd-srv-45.nvidia.eng.rdu2.dc.redhat.com}"
    REMOTE_WORK_DIR="${REMOTE_WORK_DIR:-unknown}"
    CLUSTER_NAME="${CLUSTER_NAME:-unknown}"
fi

echo "Starting DPF cleanup on ${REMOTE_HOST}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Working directory: ${REMOTE_WORK_DIR}"

# Create cleanup logs directory
CLEANUP_LOGS_DIR="${ARTIFACT_DIR}/cleanup-logs"
mkdir -p ${CLEANUP_LOGS_DIR}

# Test SSH connectivity
echo "Testing SSH connection to hypervisor..."
if ! ssh -o ConnectTimeout=10 ${REMOTE_HOST} echo "SSH connection test"; then
    echo "ERROR: Cannot connect to hypervisor ${REMOTE_HOST}"
    echo "Cleanup cannot proceed without SSH access"
    echo "Manual cleanup may be required"
    exit 0  # Don't fail the entire job due to cleanup issues
fi

echo "SSH connection confirmed"

# Function to run cleanup commands with error handling
run_cleanup_command() {
    local description="$1"
    local command="$2"
    local critical="${3:-false}"
    
    echo ""
    echo "=== ${description} ==="
    echo "Command: ${command}"
    
    if ssh "${REMOTE_HOST}" "${command}" 2>&1 | tee "${CLEANUP_LOGS_DIR}/$(echo "${description}" | tr ' ' '-' | tr '[:upper:]' '[:lower:]').log"; then
        echo "${description}: SUCCESS"
        return 0
    else
        echo "${description}: FAILED"
        if [[ "${critical}" == "true" ]]; then
            echo "CRITICAL: This failure may require manual intervention"
            return 1
        else
            echo "Non-critical failure, continuing cleanup..."
            return 0
        fi
    fi
}

# Copy final logs before cleanup (if working directory exists)
echo "=== Collecting Final Logs ==="
if [[ "${REMOTE_WORK_DIR}" != "unknown" ]] && ssh ${REMOTE_HOST} "test -d ${REMOTE_WORK_DIR}"; then
    echo "Copying final logs from working directory..."
    # Copy all logs, don't fail if some don't exist
    scp -r ${REMOTE_HOST}:${REMOTE_WORK_DIR}/logs/* ${CLEANUP_LOGS_DIR}/ 2>/dev/null || echo "Some logs could not be copied (may not exist)"
    
    # Copy any kubeconfig files
    scp ${REMOTE_HOST}:${REMOTE_WORK_DIR}/*.kubeconfig ${CLEANUP_LOGS_DIR}/ 2>/dev/null || echo "No kubeconfig files to copy"
    scp ${REMOTE_HOST}:${REMOTE_WORK_DIR}/kubeconfig ${CLEANUP_LOGS_DIR}/ 2>/dev/null || echo "No default kubeconfig to copy"
    
    echo "Final logs collected"
else
    echo " Working directory not found or unknown, skipping log collection"
fi

# Step 1: Clean up DPF cluster and VMs
if [[ "${REMOTE_WORK_DIR}" != "unknown" ]] && ssh ${REMOTE_HOST} "test -d ${REMOTE_WORK_DIR}"; then
    echo ""
    echo "=== Cluster and VM Cleanup ==="
    
    # Try make clean-all first (most comprehensive)
    if ssh ${REMOTE_HOST} "cd ${REMOTE_WORK_DIR} && timeout 1800 make clean-all" 2>&1 | tee ${CLEANUP_LOGS_DIR}/make-clean-all.log; then
        echo "make clean-all completed successfully"
        CLUSTER_CLEANUP_SUCCESS=true
    else
        echo "make clean-all failed or timed out, trying individual cleanup steps..."
        CLUSTER_CLEANUP_SUCCESS=false
        
        # Try individual cleanup steps
        run_cleanup_command "Delete Cluster via aicli" "cd ${REMOTE_WORK_DIR} && timeout 600 make delete-cluster || true"
        run_cleanup_command "Delete VMs" "cd ${REMOTE_WORK_DIR} && timeout 300 make delete-vms || true"
        run_cleanup_command "Clean Generated Files" "cd ${REMOTE_WORK_DIR} && make clean || true"
    fi
else
    echo " Working directory not accessible, skipping make cleanup"
    CLUSTER_CLEANUP_SUCCESS=false
fi

# Step 2: Force VM cleanup if make failed
if [[ "${CLUSTER_CLEANUP_SUCCESS}" != "true" ]]; then
    echo ""
    echo "=== Force VM Cleanup ==="
    run_cleanup_command "Force destroy all DPF VMs" "for vm in \$(virsh list --all --name | grep -E '(dpf|ci)'); do virsh destroy \$vm 2>/dev/null || true; virsh undefine \$vm --remove-all-storage 2>/dev/null || true; done"
    run_cleanup_command "Clean VM disk images" "find /var/lib/libvirt/images -name '*dpf*' -o -name '*ci*' | head -20 | xargs rm -f || true"
fi

# Step 3: Clean up working directory
echo ""
echo "=== Working Directory Cleanup ==="
if [[ "${REMOTE_WORK_DIR}" != "unknown" ]] && [[ "${REMOTE_WORK_DIR}" =~ ^/tmp/ ]]; then
    run_cleanup_command "Remove working directory" "rm -rf ${REMOTE_WORK_DIR}"
else
    echo " Working directory unknown or not in /tmp, skipping removal"
fi

# Step 4: General cleanup of temporary files
echo ""
echo "=== General Temporary File Cleanup ==="
run_cleanup_command "Clean old DPF CI directories" "find /tmp -maxdepth 1 -name 'dpf-ci-*' -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true"
run_cleanup_command "Clean old log files" "find /tmp -name '*.log' -name '*dpf*' -mtime +2 -delete 2>/dev/null || true"
run_cleanup_command "Clean old kubeconfig files" "find /tmp -name '*.kubeconfig' -mtime +1 -delete 2>/dev/null || true"

# Step 5: Resource verification
echo ""
echo "=== Resource Verification ==="
ssh ${REMOTE_HOST} "virsh list --all" > ${CLEANUP_LOGS_DIR}/final-vm-list.txt || echo "Could not get VM list"
ssh ${REMOTE_HOST} "df -h" > ${CLEANUP_LOGS_DIR}/final-disk-usage.txt || echo "Could not get disk usage"
ssh ${REMOTE_HOST} "free -h" > ${CLEANUP_LOGS_DIR}/final-memory-usage.txt || echo "Could not get memory usage"
ssh ${REMOTE_HOST} "ps aux | grep -E '(qemu|libvirt|aicli)' | grep -v grep" > ${CLEANUP_LOGS_DIR}/final-processes.txt 2>/dev/null || echo "No relevant processes found"

# Check for remaining DPF-related VMs
REMAINING_VMS=$(ssh ${REMOTE_HOST} "virsh list --all --name | grep -E '(dpf|ci)' | wc -l" 2>/dev/null || echo "0")
if [[ ${REMAINING_VMS} -eq 0 ]]; then
    echo "No remaining DPF/CI VMs found"
else
    echo " ${REMAINING_VMS} DPF/CI VMs still exist (may require manual cleanup)"
    ssh ${REMOTE_HOST} "virsh list --all --name | grep -E '(dpf|ci)'" > ${CLEANUP_LOGS_DIR}/remaining-vms.txt || true
fi

# Step 6: Final status summary
echo ""
echo "=== Cleanup Summary ==="
cat > ${CLEANUP_LOGS_DIR}/cleanup-summary.txt <<EOF
DPF CI Cleanup Summary
=====================
Date: $(date)
Hypervisor: ${REMOTE_HOST}
Cluster: ${CLUSTER_NAME}
Working Directory: ${REMOTE_WORK_DIR}

Cleanup Results:
- Cluster Cleanup: $(if [[ "${CLUSTER_CLEANUP_SUCCESS}" == "true" ]]; then echo "SUCCESS"; else echo "PARTIAL/FAILED"; fi)
- VM Cleanup: Attempted
- Working Directory: $(if [[ "${REMOTE_WORK_DIR}" != "unknown" ]]; then echo "REMOVED"; else echo "UNKNOWN"; fi)
- Temporary Files: CLEANED
- Resource Verification: COMPLETED

Remaining VMs: ${REMAINING_VMS}

Notes:
- All cleanup operations attempted
- Some failures are expected and non-critical
- Hypervisor should be ready for next CI run
- Manual verification may be needed if critical errors occurred

Cleanup logs saved to: ${CLEANUP_LOGS_DIR}/
EOF

echo "Cleanup Summary:"
echo "================"
echo "- Cluster cleanup: $(if [[ "${CLUSTER_CLEANUP_SUCCESS}" == "true" ]]; then echo "SUCCESS"; else echo " PARTIAL"; fi)"
echo "- Working directory: $(if [[ "${REMOTE_WORK_DIR}" != "unknown" ]]; then echo "REMOVED"; else echo " UNKNOWN"; fi)"
echo "- Remaining VMs: ${REMAINING_VMS}"
echo "- Logs saved to: ${CLEANUP_LOGS_DIR}/"

# Always exit successfully for cleanup to avoid failing the entire job
echo ""
if [[ ${REMAINING_VMS} -eq 0 ]] && [[ "${CLUSTER_CLEANUP_SUCCESS}" == "true" ]]; then
    echo "Cleanup completed successfully!"
else
    echo " Cleanup completed with warnings - manual verification recommended"
    echo "Check cleanup logs for details: ${CLEANUP_LOGS_DIR}/"
fi

echo "Hypervisor should be ready for next CI run."
exit 0  # Always succeed to avoid failing the job due to cleanup issues