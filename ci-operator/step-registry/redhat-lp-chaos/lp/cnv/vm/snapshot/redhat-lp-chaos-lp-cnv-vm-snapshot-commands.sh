#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# Load target VM list
typeset vmList
vmList=$(cat "${SHARED_DIR}/target-vm-name.txt")

function CreateAndVerifySnapshot() {
    typeset vmName="$1"
    typeset snapshotName
    snapshotName="${LPC_LP_CNV__SNAPSHOT_NAME:-chaos-snapshot}-${vmName}-$(date +%s)"
    
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${snapshotName}" \
            --arg ns "${LPC_LP_CNV__VM__NS}" \
            --arg vm "${vmName}" \
            '
            .metadata.name = $name |
            .metadata.namespace = $ns |
            .spec.source.name = $vm
            ' |
        yq -p json -o yaml eval .
    } 0<<'EOF' | oc apply -f -
apiVersion: snapshot.kubevirt.io/v1alpha1
kind: VirtualMachineSnapshot
metadata:
  name: ""
  namespace: ""
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ""
EOF

    oc wait vmsnapshot "${snapshotName}" \
        -n "${LPC_LP_CNV__VM__NS}" \
        --for=jsonpath='{.status.readyToUse}'=true \
        --timeout="${LPC_LP_CNV__SNAPSHOT_TIMEOUT}"
}

# Iterating through VMs
for vm in ${vmList}; do
    [[ -z "${vm}" ]] && continue
    CreateAndVerifySnapshot "${vm}"
done

true