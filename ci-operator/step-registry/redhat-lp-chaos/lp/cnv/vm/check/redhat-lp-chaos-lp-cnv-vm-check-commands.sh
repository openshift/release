#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

declare vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"

: '--- Starting Check the VMs ---'
: "Namespace: ${VM_NAMESPACE}"
: '------------------------------'

# Check vms status
function CheckVmRunningStatus() {
    : '--- Step 2: Checking All VM Status (VMI Ready Condition) ---'
    declare -i failedCount=0
    for vmName in ${vmList}; do
        : "Checking VM: ${vmName}..."
        oc -n "${VM_NAMESPACE}" wait "vmi/${vmName}" --for condition=Ready --timeout 0 || ((failedCount++))
    done
    if ((failedCount > 0)); then
        echo "FATAL ERROR: ${failedCount} VM(s) failed the ready status check." >&2
        return 1
    fi
    : 'All VMs are confirmed ready via API.'
}

# Install virtctl tool
function InstallAndVerifyVirtctl() {
    : '--- Step 1: Install & Verify virtctl from OpenShift Cluster ---'
    if command -v virtctl &> /dev/null; then
        # Extract GitVersion field (ignore redundant content before/after) - Local variable: lowerCamelCase
        declare installedVersion
        installedVersion=$(virtctl version --client 2>&1 | grep -oP 'GitVersion:"\K[^"]+' || true)
        if [ -z "${installedVersion}" ]; then
            installedVersion="Unknown (raw output: $(virtctl version --client 2>&1 | head -1))"
        fi
        : "virtctl already installed, version: ${installedVersion}"
    fi

    declare baseDomain
    baseDomain=$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' 2>&1)
    if [ $? -ne 0 ]; then
        echo "FATAL ERROR: Failed to get OpenShift cluster base domain (oc command failed)" >&2
        return 1
    fi
    declare virtctlHost="hyperconverged-cluster-cli-download-openshift-cnv.${baseDomain}"
    declare virtctlDownloadUrl="https://${virtctlHost}/amd64/linux/virtctl.tar.gz"

    : "Downloading virtctl from: ${virtctlDownloadUrl}"
    if ! curl -k -L --output /tmp/virtctl.tar.gz "${virtctlDownloadUrl}"; then
        echo "FATAL ERROR: Failed to download virtctl from OpenShift cluster" >&2
        return 1
    fi

    tar -zxf /tmp/virtctl.tar.gz -C /tmp/
    export PATH=/tmp:$PATH
    chmod +x /tmp/virtctl
    rm -f /tmp/virtctl.tar.gz

    if ! command -v virtctl &> /dev/null; then
        echo "FATAL ERROR: virtctl unexecutable after installation (check permissions/path)" >&2
        return 1
    fi

    declare newVersion
    newVersion=$(virtctl version --client 2>&1 | grep -oP 'GitVersion:"\K[^"]+' || true)
    if [ -z "${newVersion}" ]; then
        newVersion="Unknown (raw output: $(virtctl version --client 2>&1 | head -1))"
    fi
    : "virtctl installed successfully, version: ${newVersion}"
}

# Check ssh availability
function CheckVmSshAccess() {
    : '--- Step 3: Check SSH Availability (Port Open = Pass) ---'
    declare -i sshFailedCount=0
    for vmName in ${vmList}; do
        : "Testing SSH availability for VM ${vmName}..."
        declare sshOutput
        sshOutput=$(virtctl ssh root@"${vmName}" --namespace "${VM_NAMESPACE}" \
    --local-ssh-opts "-o BatchMode=yes" \
    --local-ssh-opts "-o StrictHostKeyChecking=no" \
    --local-ssh-opts "-o ConnectTimeout=3" 2>&1 | grep "Permission denied" || true)

        # No "Permission denied" → SSH unavailable (port closed/connection failed)
        if [[ -z "${sshOutput}" ]]; then
            echo "ERROR: SSH unavailable for VM ${vmName} (no Permission denied; likely port closed/connection failed)" >&2
            echo "Debug: SSH output → ${sshOutput}" >&2
            ((sshFailedCount++))
        else
            : "SSH available for VM ${vmName} (Permission denied detected → port open)"
        fi
    done

    if ((sshFailedCount > 0)); then
        echo "FATAL ERROR: ${sshFailedCount} VM(s) failed SSH availability check" >&2
        return 1
    fi
    : 'All VMs passed SSH availability check (ports open)'
}

# Main Execution Flow
InstallAndVerifyVirtctl
CheckVmRunningStatus
CheckVmSshAccess

true