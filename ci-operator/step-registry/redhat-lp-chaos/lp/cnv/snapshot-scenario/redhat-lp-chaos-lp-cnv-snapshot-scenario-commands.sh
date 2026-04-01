#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

# --- 1. Environment & JUnit Setup ---
typeset artifactDir="${ARTIFACT_DIR:-/tmp/artifacts}"
typeset stepId
stepId=$(basename "${artifactDir}")
typeset -i startTime
startTime=$(date +%s)
typeset junitReport="${artifactDir}/junit_${stepId}.xml"
typeset waitTimeout="${WAIT_TIMEOUT:-15m}"

function FinalizeJunit() {
    typeset -i exitCode=$?
    typeset -i duration
    duration=$(( $(date +%s) - startTime ))

    # Generate JUnit report for CI aggregation
    cat <<EOF > "${junitReport}"
<testsuite name="lp-cnv-chaos-suite" tests="1" failures="$([[ ${exitCode} -eq 0 ]] && echo 0 || echo 1)" time="${duration}">
  <testcase name="${stepId}" classname="cnv-chaos-matrix" time="${duration}">
    $([[ ${exitCode} -ne 0 ]] && echo "<failure message='Chaos test failed'>Check build-log.txt in artifacts</failure>")
  </testcase>
</testsuite>
EOF
    true
}
trap FinalizeJunit EXIT

# --- 2. Variable Initialization ---
# Reading VM list into string then array to ensure multi-line compatibility
typeset vmList
vmList="$(cat "${SHARED_DIR}/target-vm-name.txt")"
typeset -a vmArray
read -r -a vmArray <<< "${vmList}"

# Target the first VM from the array for chaos injection
typeset vmName="${vmArray[0]}"
typeset vmNamespace="${LPC_LP_CNV__VM__NS:-default}"
typeset snapshotName="snap-${stepId}"
typeset restoreName="restore-${snapshotName}"
typeset targetNamespace

# Auto-infer target namespace based on component
if [[ -z "${TARGET_NAMESPACE:-}" ]]; then
    case "${TARGET_COMPONENT:-}" in
        (apiserver)           targetNamespace="openshift-kube-apiserver" ;;
        (virt-api|virt-handler|snapshot-controller) targetNamespace="openshift-cnv" ;;
        (csi-driver)          targetNamespace="openshift-cluster-csi-drivers" ;;
        (*)                   targetNamespace="openshift-cnv" ;;
    esac
else
    targetNamespace="${TARGET_NAMESPACE}"
fi

# --- 3. Core Logic Functions ---

function DoSnapshotCreate() {
    : "Action: Creating VMSnapshot ${snapshotName} for VM ${vmName}"
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${snapshotName}" \
            --arg ns "${vmNamespace}" \
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

    # Sentinel: Wait for InProgress phase in a quiet subshell to avoid log spam
    ( set +x
      timeout 60s bash -c "until [[ \$(oc get vmsnapshot '${snapshotName}' -n '${vmNamespace}' -o jsonpath='{.status.phase}' 2>/dev/null) == 'InProgress' ]]; do sleep 0.5; done"
    ) || : "Warning: Phase might have transitioned or timeout reached"
    
    true
}

function DoSnapshotDelete() {
    : "Action: Deleting VMSnapshot ${snapshotName}"
    oc get vmsnapshot "${snapshotName}" -n "${vmNamespace}"
    
    # Background deletion to allow sentinel monitoring
    oc delete vmsnapshot "${snapshotName}" -n "${vmNamespace}" &
    
    ( set +x
      timeout 30s bash -c "until oc get vmsnapshot '${snapshotName}' -n '${vmNamespace}' -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q 'T'; do sleep 0.2; done"
    )
    
    true
}

function DoSnapshotRestore() {
    : "Action: Restoring VM ${vmName} from ${snapshotName}"
    virtctl stop "${vmName}" -n "${vmNamespace}" || true
    
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${restoreName}" \
            --arg ns "${vmNamespace}" \
            --arg vm "${vmName}" \
            --arg snap "${snapshotName}" \
            '
            .metadata.name = $name |
            .metadata.namespace = $ns |
            .spec.target.name = $vm |
            .spec.virtualMachineSnapshotName = $snap
            ' |
        yq -p json -o yaml eval .
    } 0<<'EOF' | oc apply -f -
apiVersion: snapshot.kubevirt.io/v1alpha1
kind: VirtualMachineRestore
metadata:
  name: ""
  namespace: ""
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ""
  virtualMachineSnapshotName: ""
EOF

    ( set +x
      timeout 30s bash -c "until oc get vmrestore '${restoreName}' -n '${vmNamespace}' &>/dev/null; do sleep 0.5; done"
    )
    
    true
}

# --- 4. Execution Flow ---

: "[CHAOS START] Scenario: ${stepId}"

case "${OPERATION:-create}" in
    (create)  DoSnapshotCreate ;;
    (delete)  DoSnapshotDelete ;;
    (restore) DoSnapshotRestore ;;
    (*)       echo "ERROR: Unsupported operation: ${OPERATION}" >&2; exit 1 ;;
esac

: "Action: Killing ${TARGET_COMPONENT} pods (Label: ${TARGET_LABEL})"
oc delete pod -n "${targetNamespace}" -l "${TARGET_LABEL}" --force --grace-period=0 --ignore-not-found=true || : "Info: Pod deletion call handled"

if [[ "${TARGET_COMPONENT:-}" == "apiserver" ]]; then
    ( set +x
      timeout 300s bash -c "until oc get nodes &>/dev/null; do sleep 5; done"
    )
fi

case "${OPERATION:-create}" in
    (create)
        oc wait vmsnapshot "${snapshotName}" -n "${vmNamespace}" --for=jsonpath='{.status.readyToUse}'=true --timeout="${waitTimeout}"
        ;;
    (restore)
        oc wait vmrestore "${restoreName}" -n "${vmNamespace}" --for=jsonpath='{.status.complete}'=true --timeout="${waitTimeout}"
        virtctl start "${vmName}" -n "${vmNamespace}" || true
        ;;
    (delete)
        oc wait vmsnapshot "${snapshotName}" -n "${vmNamespace}" --for=delete --timeout="${waitTimeout}"
        ;;
esac

: "Case ${stepId} completed"
sleep 30

true