#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"
declare binDir="/tmp/bin"

: '--- Starting Check the VMs ---'
: "Namespace: ${LPC_LP_CNV__VM__NS}"
: '------------------------------'

# Set virtctl path
mkdir -p "${binDir}"
if ! [[ "${PATH}" =~ :?"${binDir}":? ]]; then
    export PATH="${binDir}:${PATH}"
fi

# Check vms status
function CheckVmRunningStatus() {
    declare -i failedCount=0
    for vmName in ${vmList}; do
        oc -n "${LPC_LP_CNV__VM__NS}" wait "vmi/${vmName}" --for condition=Ready --timeout 0 || ((++failedCount))
    done
    if ((failedCount > 0)); then
        : "FATAL ERROR: ${failedCount} VM(s) failed the ready status check."
        return 1
    fi
}

# Install virtctl tool
function InstallAndVerifyVirtctl() {
    declare baseURL
    if ! baseURL=$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}'); then
        : "FATAL ERROR: Failed to get OpenShift cluster base domain."
        return 1
    fi

    declare dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    if ! curl -kfsSL "${dlURL}" | tar zx -C "${binDir}"; then
        : "FATAL ERROR: Failed to download and extract virtctl."
        return 1
    fi

    if ! virtctl version --client; then
        : "FATAL ERROR: virtctl installed but failed to execute after setup."
        return 1
    fi
}

# Check ssh availability
function CheckVmIPConnectivity() {
    declare -i sshFailedCount=0
    declare sshOpts=(
        --local-ssh-opts "-o BatchMode=yes"
        --local-ssh-opts "-o LogLevel=ERROR"
        --local-ssh-opts "-o UserKnownHostsFile=/dev/null"
        --local-ssh-opts "-o StrictHostKeyChecking=no"
        --local-ssh-opts "-o ConnectTimeout=3"
    )
    for vmName in ${vmList}; do
        : "Testing IP connection via SSH for VM ${vmName}..."
        sshOutput=$(virtctl ssh root@"vmi/${vmName}" --namespace "${LPC_LP_CNV__VM__NS}" "${sshOpts[@]}" 2>&1 ) || {
            # Check for SSH Auth failure, as it actually still confirm that IP connection is working.
            { echo "${sshOutput}" | grep 'Permission denied'; } || ((++sshFailedCount))
        }
    done
    : "Total failures: ${sshFailedCount}"
    if ((sshFailedCount > 0)); then
        return 1
    else
        return 0
    fi
}

# Main Execution Flow
InstallAndVerifyVirtctl
CheckVmRunningStatus
CheckVmIPConnectivity

true