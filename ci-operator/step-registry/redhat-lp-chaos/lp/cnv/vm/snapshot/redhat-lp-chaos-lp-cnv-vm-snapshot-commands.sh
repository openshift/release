#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs uv

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/TestReport--JUnit.sh
)"

typeset -i startTime="${SECONDS}"

typeset tcMsg='-Unknown Error'

function UpdJUnit() {
    typeset tcMsg="${1}"; (($#)) && shift

    typeset stepId="${BASH_SOURCE[0]##*/}"; stepId="${stepId%-commands.sh}"
    typeset tcRes=''

    case ${tcMsg} in
      (-*)  tcRes=-e; tcMsg="${tcMsg#-}";;
      ('')  ;;
      (*)   tcRes=-f;;
    esac

    TestReport--JUnit--AddTC \
        "${ARTIFACT_DIR}/junit--${stepId}--${LPC_LP_CNV__VM__SNAPSHOT__OPERATION}.xml" \
        "${LPC_LP_CNV__RPT_NAME}" \
        "${LPC_LP_CNV__TS_NAME}" \
        "${LPC_LP_CNV__TC_NAME}" \
        "$((SECONDS - startTime))" \
        "${tcRes}" "${tcMsg}" || :
}

trap 'UpdJUnit "${tcMsg}"' EXIT

typeset -a vmArray
read -r -a vmArray 0< "${SHARED_DIR}/target-vm-name.txt"

function SnapshotCreate() {
    typeset vmName="${1:?SnapshotCreate: vmName required}"
    typeset snapshotName="${LPC_LP_CNV__SNAPSHOT_NAME}--${vmName}"

    oc delete vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" \
        --wait=true --ignore-not-found=true

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

    printf '%s' "${snapshotName}" > "${SHARED_DIR}/snapshot-name--${vmName}.txt"
}

function SnapshotRestore() {
    typeset vmName="${1:?SnapshotRestore: vmName required}"
    typeset snapshotName
    snapshotName=$(< "${SHARED_DIR}/snapshot-name--${vmName}.txt")
    typeset restoreName="restore--${vmName}"

    oc delete vmrestore "${restoreName}" -n "${LPC_LP_CNV__VM__NS}" \
        --wait=true --ignore-not-found=true

    virtctl stop "${vmName}" -n "${LPC_LP_CNV__VM__NS}" || : "INFO: virtctl stop ${vmName} returned non-zero (may already be stopped)"

    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${restoreName}" \
            --arg ns "${LPC_LP_CNV__VM__NS}" \
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

    oc wait vmrestore "${restoreName}" \
        -n "${LPC_LP_CNV__VM__NS}" \
        --for=jsonpath='{.status.complete}'=true \
        --timeout="${LPC_LP_CNV__SNAPSHOT_TIMEOUT}"

    virtctl start "${vmName}" -n "${LPC_LP_CNV__VM__NS}"
    oc wait "vmi/${vmName}" \
        -n "${LPC_LP_CNV__VM__NS}" \
        --for=condition=Ready \
        --timeout="${LPC_LP_CNV__SNAPSHOT_TIMEOUT}"
}

function SnapshotDelete() {
    typeset vmName="${1:?SnapshotDelete: vmName required}"
    typeset snapshotName
    snapshotName=$(< "${SHARED_DIR}/snapshot-name--${vmName}.txt")

    oc delete vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" \
        --wait=false --ignore-not-found=true

    if ! oc wait vmsnapshot "${snapshotName}" \
            -n "${LPC_LP_CNV__VM__NS}" \
            --for=delete --timeout="${LPC_LP_CNV__SNAPSHOT_TIMEOUT}" 2>/dev/null; then
        typeset _snap_ref
        _snap_ref="$(oc get vmsnapshot "${snapshotName}" -n "${LPC_LP_CNV__VM__NS}" --ignore-not-found -o name)"
        [[ -z "${_snap_ref}" ]] || { tcMsg="vmsnapshot '${snapshotName}' still exists after delete timeout"; false; }
    fi
}

for vmName in "${vmArray[@]}"; do
    [[ -n "${vmName}" ]] || continue
    case "${LPC_LP_CNV__VM__SNAPSHOT__OPERATION}" in
        (create)
            SnapshotCreate "${vmName}" || { tcMsg="Snapshot create failed for vm=${vmName}"; false; }
            ;;
        (restore)
            SnapshotRestore "${vmName}" || { tcMsg="Snapshot restore failed for vm=${vmName}"; false; }
            ;;
        (delete)
            SnapshotDelete "${vmName}" || { tcMsg="Snapshot delete failed for vm=${vmName}"; false; }
            ;;
        (*)
            tcMsg="-Unsupported LPC_LP_CNV__VM__SNAPSHOT__OPERATION='${LPC_LP_CNV__VM__SNAPSHOT__OPERATION}'"
            false
            ;;
    esac
done

tcMsg=''
true
