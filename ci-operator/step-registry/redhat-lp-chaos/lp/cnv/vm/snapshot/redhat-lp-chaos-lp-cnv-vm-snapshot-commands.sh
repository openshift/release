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
        "${ARTIFACT_DIR}/junit--${stepId}.xml" \
        "${LPC_LP_CNV__RPT_NAME}" \
        "${LPC_LP_CNV__TS_NAME}" \
        "${LPC_LP_CNV__TC_NAME}" \
        "$((SECONDS - startTime))" \
        "${tcRes}" "${tcMsg}" || :
}

trap 'UpdJUnit "${tcMsg}"' EXIT

typeset vmList
vmList=$(< "${SHARED_DIR}/target-vm-name.txt")

function CreateAndVerifySnapshot() {
    typeset vmName="${1:?CreateAndVerifySnapshot: vmName is required as non-empty string.}"
    typeset snapshotName
    snapshotName="${LPC_LP_CNV__SNAPSHOT_NAME}--${vmName}--${SECONDS}"

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

    true
}

for vm in ${vmList}; do
    [ -z "${vm}" ] && continue
    CreateAndVerifySnapshot "${vm}" || { tcMsg="CreateAndVerifySnapshot: Failed for vm=${vm}"; false; }
done

tcMsg=''
true
