#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset -a vmArray
read -r -a vmArray 0< "${SHARED_DIR}/target-vm-name.txt"

function DeleteAllVms() {
    typeset -i failedCount=0
    for vmName in "${vmArray[@]}"; do
        oc delete vm "${vmName}" -n "${LPC_LP_CNV__VM__NS}" \
            --ignore-not-found=true \
            --grace-period=0 || {
            : "WARNING: Failed to delete VM ${vmName}."
            ((++failedCount))
        }
    done

    oc wait --for=delete pod -l app=chaos-target -n "${LPC_LP_CNV__VM__NS}" --timeout=2m
    if ((failedCount > 0)); then
        : "WARNING: Failed to delete ${failedCount} VM(s)."
        return 1
    fi

    true
}

function DeleteNamespace() {
    oc delete namespace "${LPC_LP_CNV__VM__NS}" --ignore-not-found=true
}

typeset _vmDelFailed=0
DeleteAllVms || _vmDelFailed=1
DeleteNamespace
((_vmDelFailed == 0))

true
