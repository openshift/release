#!/bin/bash
set -euxo pipefail

VM_LIST=$(cat "${SHARED_DIR}/target_vm_name.txt")
VM_NAMESPACE=$(cat "${SHARED_DIR}/target_vm_namespace.txt")

: "--- Starting Check the VMs ---"
: "VMs to Check: $VM_LIST"
: "Namespace: $VM_NAMESPACE"
: "------------------------------"

function check_vm_running_status() {
    : "--- Checking All VM Status (VMI Ready Condition) ---"

    declare -i FAILED_COUNT=0

    for VM_NAME in ${VM_LIST}; do
        : "Checking VM: ${VM_NAME}..."

        # 1. Check VMI existence
        if ! oc get vmi "${VM_NAME}" -n "${VM_NAMESPACE}" > /dev/null 2>&1; then
            : "ERROR: VMI resource ${VM_NAME} not found." >&2
            FAILED_COUNT+=1
            continue
        fi

        # 2. Check Ready condition
        VMI_READY_STATUS=$(oc get vmi "${VM_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        if [[ "${VMI_READY_STATUS}" == "True" ]]; then
            : "VM ${VM_NAME}: Ready State is True (PASS)."
        else
            : "ERROR: VM ${VM_NAME} failed to reach Ready state (Status: ${VMI_READY_STATUS})." >&2
            FAILED_COUNT+=1
        fi
    done

    if [[ ${FAILED_COUNT} -gt 0 ]]; then
        : "FATAL ERROR: ${FAILED_COUNT} VM(s) failed the Ready status check." >&2
        return 1
    fi
    : "All VMs are confirmed Ready via API."
    return 0
}

# Execute checks sequentially. If one fails (returns 1), the script exits due to 'set -e'.
check_vm_running_status

: " Check passed."