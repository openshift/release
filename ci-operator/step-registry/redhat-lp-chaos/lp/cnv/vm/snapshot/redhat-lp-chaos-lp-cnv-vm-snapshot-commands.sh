#!/bin/bash

# Junit report
typeset step_id
step_id=$(basename "${ARTIFACT_DIR}")
JUNIT_REPORT="${ARTIFACT_DIR}/junit_${step_id}.xml"
START_TIME=$(date +%s)

function finalize_junit() {
    local exit_code=$?
    local duration=$(( $(date +%s) - START_TIME ))
    
    local failures=0
    [[ ${exit_code} -ne 0 ]] && failures=1
    cat <<EOF > "${JUNIT_REPORT}"
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="lp-cnv-chaos-suite" tests="1" failures="${failures}" errors="0" skipped="0" time="${duration}">
    <testcase name="chaos-test-${step_id}" classname="cnv-chaos-matrix" time="${duration}">
      $([[ ${exit_code} -ne 0 ]] && echo "<failure message='Step failed with exit code ${exit_code}'>Detailed logs can be found in build-log.txt within the artifacts tab.</failure>")
    </testcase>
  </testsuite>
</testsuites>
EOF
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
