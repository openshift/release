#!/bin/bash
set -euxo pipefail

VM_LIST=$(cat "${SHARED_DIR}/target_vm_name.txt")
VM_NAMESPACE=$(cat "${SHARED_DIR}/target_vm_namespace.txt")

echo "--- Starting Check the VMs ---"
echo "VMs to Check: $VM_LIST"
echo "Namespace: $VM_NAMESPACE"
echo "------------------------------"

function check_vm_running_status() {
    echo "--- 2. Checking All VM Status (VMI Ready Condition) ---"

    declare -i FAILED_COUNT=0

    for VM_NAME in $VM_LIST; do
        echo "Checking VM: $VM_NAME..."

        # 1. Check VMI existence
        if ! oc get vmi "$VM_NAME" -n "$VM_NAMESPACE" > /dev/null 2>&1; then
            echo "ERROR: VMI resource $VM_NAME not found." >&2
            FAILED_COUNT+=1
            continue
        fi

        # 2. Check Ready condition
        VMI_READY_STATUS=$(oc get vmi "$VM_NAME" -n "$VM_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
        if [[ "$VMI_READY_STATUS" == "True" ]]; then
            echo "VM $VM_NAME: Ready State is True (PASS)."
        else
            echo "ERROR: VM $VM_NAME failed to reach Ready state (Status: $VMI_READY_STATUS)." >&2
            FAILED_COUNT+=1
        fi
    done

    if [[ $FAILED_COUNT -gt 0 ]]; then
        echo "FATAL ERROR: $FAILED_COUNT VM(s) failed the Ready status check." >&2
        return 1
    fi
    echo "All VMs are confirmed Ready via API."
    return 0
}

# Execute checks sequentially. If one fails (returns 1), the script exits due to 'set -e'.
check_vm_running_status

echo " Check passed."