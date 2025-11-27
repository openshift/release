#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"
read -r -a vmArray <<< "${vmList}"

: '--- Starting VM and Namespace Cleanup ---'
: "Namespace: ${LPC_LP_CNV__VM__NS}"
: '-----------------------------------------'

# Delete vms
function DeleteAllVms() {
    declare -i failedCount=0
    for vmName in "${vmArray[@]}"; do
        oc delete vm "${vmName}" -n "${LPC_LP_CNV__VM__NS}" \
            --ignore-not-found=true \
            --grace-period=0 || {
            : "WARNING: Failed to delete VM ${vmName}."
            failedCount+=1
        }
    done

    oc wait --for=delete pod -l app=chaos-target -n "${LPC_LP_CNV__VM__NS}" --timeout=2m
    if [[ ${failedCount} -gt 0 ]]; then
        : "WARNING: Failed to delete ${failedCount} VM(s)."
        return 1
    fi

    true
}

# Delete namespace
function DeleteNamespace() {
    oc delete namespace "${LPC_LP_CNV__VM__NS}" --ignore-not-found=true
}

# Main execution flow
DeleteAllVms
DeleteNamespace

true