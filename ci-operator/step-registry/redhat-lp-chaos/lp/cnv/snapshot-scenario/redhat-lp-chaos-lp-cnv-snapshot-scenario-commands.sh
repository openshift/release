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

    typeset stepId="kill-${TARGET_COMPONENT:-unknown}-on-${OPERATION:-unknown}"
    typeset tcRes=''

    case ${tcMsg} in
      (-*)  tcRes=-e; tcMsg="${tcMsg#-}";;
      ('')  ;;
      (*)   tcRes=-f;;
    esac

    TestReport--JUnit--AddTC \
        "${ARTIFACT_DIR}/junit--${stepId}.xml" \
        "${LPC_LP_CNV__RPT_NAME}" \
        "${LPC_LP_CNV__TS_NAME}" \
        "${LPC_LP_CNV__TC_NAME}" \
        "$((SECONDS - startTime))" \
        "${tcRes}" "${tcMsg}" || :
}

trap 'UpdJUnit "${tcMsg}"' EXIT

: "${LPC_LP_CNV__VM__NS:?LPC_LP_CNV__VM__NS must be set}"
: "${TARGET_NAMESPACE:?TARGET_NAMESPACE must be set}"
: "${TARGET_COMPONENT:?TARGET_COMPONENT must be set}"
: "${OPERATION:?OPERATION must be set}"
: "${TARGET_LABEL:?TARGET_LABEL must be set}"
[[ -f "${SHARED_DIR}/target-vm-name.txt" ]] || {
    echo "ERROR: ${SHARED_DIR}/target-vm-name.txt not found" >&2
    tcMsg='-target-vm-name.txt not found in SHARED_DIR'
    false
}

typeset vmList
vmList=$(< "${SHARED_DIR}/target-vm-name.txt")
typeset -a vmArray
read -r -a vmArray <<< "${vmList}"
typeset vmName="${vmArray[0]:?target-vm-name.txt is empty — no VM name to operate on}"
typeset vmNamespace="${LPC_LP_CNV__VM__NS}"
typeset waitTimeout="${WAIT_TIMEOUT:-15m}"
typeset snapshotName="snap-${vmName}"
typeset restoreName="restore-${vmName}"
typeset targetNamespace="${TARGET_NAMESPACE}"

function DoSnapshotCreate() {
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

    # Non-fatal: fast storage may complete before InProgress is observable.
    ( set +x
      timeout 60s bash -c "until [[ \$(oc get vmsnapshot '${snapshotName}' -n '${vmNamespace}' -o jsonpath='{.status.phase}' 2>/dev/null) == 'InProgress' ]]; do sleep 0.5; done"
    ) || :

    true
}

function DoSnapshotRestore() {
    virtctl stop "${vmName}" -n "${vmNamespace}" || :

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

    # Non-fatal: fast storage may complete before resource is observable.
    ( set +x
      timeout 60s bash -c "until oc get vmrestore '${restoreName}' -n '${vmNamespace}' &>/dev/null; do sleep 0.5; done"
    ) || :

    true
}

function DoSnapshotDelete() {
    oc delete vmsnapshot "${snapshotName}" -n "${vmNamespace}" --wait=false --ignore-not-found=true

    true
}

: "[CHAOS START] component=${TARGET_COMPONENT} operation=${OPERATION} vm=${vmName} ns=${vmNamespace}"

case "${OPERATION}" in
    (create)
        DoSnapshotCreate || { tcMsg="Snapshot create operation failed"; false; }
        ;;
    (restore)
        DoSnapshotRestore || { tcMsg="Snapshot restore operation failed"; false; }
        ;;
    (delete)
        DoSnapshotDelete || { tcMsg="Snapshot delete operation failed"; false; }
        ;;
    (*)
        tcMsg="-Unsupported OPERATION '${OPERATION}'"
        false
        ;;
esac

oc delete pod -n "${targetNamespace}" -l "${TARGET_LABEL}" --force --grace-period=0 --ignore-not-found=true || :

if [[ "${TARGET_COMPONENT}" == "apiserver" ]]; then
    ( set +x
      timeout 300s bash -c "until oc get nodes &>/dev/null; do sleep 5; done"
    ) || { tcMsg="apiserver pods killed but nodes unreachable after 300s"; false; }
fi

case "${OPERATION}" in
    (create)
        oc wait vmsnapshot "${snapshotName}" -n "${vmNamespace}" \
            --for=jsonpath='{.status.readyToUse}'=true \
            --timeout="${waitTimeout}" \
            || { tcMsg="Snapshot not readyToUse within ${waitTimeout}"; false; }
        ;;
    (restore)
        oc wait vmrestore "${restoreName}" -n "${vmNamespace}" \
            --for=jsonpath='{.status.complete}'=true \
            --timeout="${waitTimeout}" \
            || { tcMsg="Restore not complete within ${waitTimeout}"; false; }
        virtctl start "${vmName}" -n "${vmNamespace}" || :
        ;;
    (delete)
        if ! oc wait vmsnapshot "${snapshotName}" -n "${vmNamespace}" \
                --for=delete --timeout="${waitTimeout}" 2>/dev/null; then
            typeset _snap_ref
            _snap_ref="$(oc get vmsnapshot "${snapshotName}" -n "${vmNamespace}" --ignore-not-found -o name)"
            [[ -z "${_snap_ref}" ]] || { tcMsg="vmsnapshot '${snapshotName}' still exists after delete timeout"; false; }
        fi
        ;;
esac

: "[CHAOS COMPLETE] component=${TARGET_COMPONENT} operation=${OPERATION} vm=${vmName}"

sleep 30

tcMsg=''
true
