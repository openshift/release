#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

declare vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"
read -r -a vmArray <<< "${vmList}"

: '--- Starting VM and Namespace Cleanup ---'
: "Namespace: ${VM_NAMESPACE}"
: '-----------------------------------------'

# DeleteVms
function DeleteAllVms() {
    declare -i failedCount=0
    for vmName in "${vmArray[@]}"; do
        : "Attempting deletion of VM: ${vmName}"
        oc delete vm "${vmName}" -n "${VM_NAMESPACE}" \
            --ignore-not-found=true \
            --grace-period=0 || {
            echo "WARNING: Failed to delete VM ${vmName}." >&2
            failedCount+=1
        }
    done

    : 'Waiting 2m for all VMI Pods to terminate...'
    oc wait --for=delete pod -l app=chaos-target -n "${VM_NAMESPACE}" --timeout=2m || true
    if [[ ${failedCount} -gt 0 ]]; then
        echo "WARNING: Failed to delete ${failedCount} VM(s)." >&2
        return 1
    fi

    true
}

# DeleteNS
function DeleteNamespace() {
    : '--- 2. Deleting Test Namespace ---'
    oc delete namespace "${VM_NAMESPACE}" --ignore-not-found=true || {
        echo "ERROR: Failed to submit namespace deletion for ${VM_NAMESPACE}." >&2
        return 1
    }

    true
}

# Main Execution Flow
DeleteAllVms
DeleteNamespace

: 'Cleanup process completed successfully'
true