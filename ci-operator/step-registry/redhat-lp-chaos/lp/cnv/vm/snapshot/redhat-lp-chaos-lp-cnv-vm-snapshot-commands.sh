#!/bin/bash
# JUnit Support Start
JUNIT_REPORT="${ARTIFACT_DIR}/junit_cnv_vm_snapshot.xml"
START_TIME=$(date +%s)

function finalize_junit() {
    local exit_code=$?
    local duration=$(( $(date +%s) - START_TIME ))
    if [[ ${exit_code} -eq 0 ]]; then
        cat <<EOF > "${JUNIT_REPORT}"
<testsuite name="lp-cnv-chaos" tests="1" failures="0" time="${duration}">
  <testcase name="vm-snapshot-verification" classname="cnv-chaos-snapshot" time="${duration}" />
</testsuite>
EOF
    else
        cat <<EOF > "${JUNIT_REPORT}"
<testsuite name="lp-cnv-chaos" tests="1" failures="1" time="${duration}">
  <testcase name="vm-snapshot-verification" classname="cnv-chaos-snapshot" time="${duration}">
    <failure message="Step failed">Exit code: ${exit_code}. Check build-log.txt for details.</failure>
  </testcase>
</testsuite>
EOF
    fi
}
trap finalize_junit EXIT

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
