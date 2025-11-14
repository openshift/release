#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

declare vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"
read -r -a vmArray <<< "${vmList}"

: '--- Starting VM and Namespace Cleanup ---'
: "Namespace: ${LPC_LP_CNV_VM_CLEAN__NS}"
: '-----------------------------------------'

# DeleteVms
function DeleteAllVms() {
    declare -i failedCount=0
    for vmName in "${vmArray[@]}"; do
        oc delete vm "${vmName}" -n "${LPC_LP_CNV_VM_CLEAN__NS}" \
            --ignore-not-found=true \
            --grace-period=0 || {
            echo "WARNING: Failed to delete VM ${vmName}." >&2
            failedCount+=1
        }
    done

    oc wait --for=delete pod -l app=chaos-target -n "${LPC_LP_CNV_VM_CLEAN__NS}" --timeout=2m
    if [[ ${failedCount} -gt 0 ]]; then
        echo "WARNING: Failed to delete ${failedCount} VM(s)." >&2
        return 1
    fi

    true
}

# DeleteNS
function DeleteNamespace() {
    oc delete namespace "${LPC_LP_CNV_VM_CLEAN__NS}" --ignore-not-found=true
}

# Main Execution Flow
DeleteAllVms
DeleteNamespace

true