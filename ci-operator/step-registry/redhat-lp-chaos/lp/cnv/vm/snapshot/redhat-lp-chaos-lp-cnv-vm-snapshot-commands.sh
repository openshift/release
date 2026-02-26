#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

: "Reading target VM list..."
typeset vmList
vmList=$(cat "${SHARED_DIR}/target-vm-name.txt")

function CreateAndVerifySnapshot() {
    typeset vmName="$1"
    typeset snapshotName="${LPC_LP_CNV__SNAPSHOT_NAME:-chaos-snapshot}-${vmName}-$(date +%s)"
    typeset -i waitTime=0
    typeset -i timeoutMin="${LPC_LP_CNV__SNAPSHOT_TIMEOUT_MIN:-10}"

    : "Action: Creating VirtualMachineSnapshot for ${vmName}"

    oc apply -f - <<EOF
apiVersion: snapshot.kubevirt.io/v1alpha1
kind: VirtualMachineSnapshot
metadata:
  name: ${snapshotName}
  namespace: ${LPC_LP_CNV__VM__NS}
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${vmName}
EOF

    : "Wait: Monitoring snapshot ${snapshotName} readiness..."
    while [[ "$(oc get vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" -o jsonpath='{.status.readyToUse}' 2>/dev/null)" != "true" ]]; do
        if (( waitTime > timeoutMin * 60 )); then
            : "Error: Timeout waiting for snapshot ${snapshotName} after ${timeoutMin} minutes"
            oc get vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" -o yaml
            return 1
        fi

        typeset phase
        phase=$(oc get vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "${phase}" == "Failed" ]]; then
            : "Error: Snapshot ${snapshotName} transitioned to Failed phase"
            oc get vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" -o yaml
            return 1
        fi

        sleep 15
        waitTime=$((waitTime + 15))
    done

    : "SUCCESS: Snapshot ${snapshotName} created for VM ${vmName}."
    true
}

: "Process: Iterating through VMs..."
for vm in ${vmList}; do
    [ -z "${vm}" ] && continue
    CreateAndVerifySnapshot "${vm}"
done

true