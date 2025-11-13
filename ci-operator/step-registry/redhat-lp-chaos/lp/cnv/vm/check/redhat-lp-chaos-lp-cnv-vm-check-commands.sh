#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

declare vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"

: '--- Starting Check the VMs ---'
: "Namespace: ${LPC_LP_CNV_VM_CHECK__NS}"
: '------------------------------'

# Check vms status
function CheckVmRunningStatus() {
    declare -i failedCount=0
    for vmName in ${vmList}; do
        oc -n "${LPC_LP_CNV_VM_CHECK__NS}" wait "vmi/${vmName}" --for condition=Ready --timeout 0 || ((failedCount++))
    done
    if ((failedCount > 0)); then
        echo "FATAL ERROR: ${failedCount} VM(s) failed the ready status check." >&2
        return 1
    fi
}

# Install virtctl tool
function InstallAndVerifyVirtctl() {
    declare binDir="/tmp/bin"
    mkdir -p "${binDir}" || { echo "FATAL ERROR: Failed to create bin directory ${binDir}." >&2; return 1; }

    declare baseURL
    if ! baseURL=$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}'); then
        echo "FATAL ERROR: Failed to get OpenShift cluster base domain." >&2; return 1
    fi

    declare dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    if ! curl -kfsSL "${dlURL}" | tar zx -C "${binDir}"; then
        echo "FATAL ERROR: Failed to download and extract virtctl." >&2; return 1
    fi

    if ! [[ "${PATH}" =~ :?"${binDir}":? ]]; then
        export PATH="${binDir}:${PATH}"
    fi

    if ! virtctl version --client; then
        echo "FATAL ERROR: virtctl installed but failed to execute after setup." >&2; return 1
    fi
}

# Check ssh availability
function CheckVmSshAccess() {
    declare -i sshFailedCount=0
    for vmName in ${vmList}; do
        : "Testing SSH availability for VM ${vmName}..."
        declare sshOutput
        sshOutput=$(virtctl ssh root@"${vmName}" --namespace "${LPC_LP_CNV_VM_CHECK__NS}" \
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