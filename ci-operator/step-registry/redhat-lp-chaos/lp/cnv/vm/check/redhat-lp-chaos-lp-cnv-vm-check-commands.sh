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

typeset startTime="${SECONDS}"
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

typeset -a vmArray
read -r -a vmArray 0< "${SHARED_DIR}/target-vm-name.txt"
typeset binDir="/tmp/bin"

mkdir -p "${binDir}"
if ! [[ "${PATH}" =~ :?"${binDir}":? ]]; then
    export PATH="${binDir}:${PATH}"
fi

function CheckVmRunningStatus() {
    typeset -i failedCount=0
    for vmName in "${vmArray[@]}"; do
        oc -n "${LPC_LP_CNV__VM__NS}" wait "vmi/${vmName}" --for condition=Ready --timeout 0 || ((++failedCount))
    done
    if ((failedCount > 0)); then
        : "FATAL ERROR: ${failedCount} VM(s) failed the ready status check."
        return 1
    fi
    true
}

function InstallAndVerifyVirtctl() {
    typeset baseURL
    if ! baseURL=$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}'); then
        : "FATAL ERROR: Failed to get OpenShift cluster base domain."
        return 1
    fi

    typeset dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    if ! curl -kfsSL "${dlURL}" | tar zx -C "${binDir}"; then
        : "FATAL ERROR: Failed to download and extract virtctl."
        return 1
    fi

    if ! virtctl version --client; then
        : "FATAL ERROR: virtctl installed but failed to execute after setup."
        return 1
    fi
}

function CheckVmIPConnectivity() {
    typeset -i sshFailedCount=0
    typeset -a sshOpts=(
        --local-ssh-opts "-o BatchMode=yes"
        --local-ssh-opts "-o LogLevel=ERROR"
        --local-ssh-opts "-o UserKnownHostsFile=/dev/null"
        --local-ssh-opts "-o StrictHostKeyChecking=no"
        --local-ssh-opts "-o ConnectTimeout=3"
    )
    typeset sshOutput
    for vmName in "${vmArray[@]}"; do
        : "Testing IP connection via SSH for VM ${vmName}..."
        sshOutput=$(virtctl ssh root@"vmi/${vmName}" --namespace "${LPC_LP_CNV__VM__NS}" "${sshOpts[@]}" 2>&1) || {
            # Check for SSH Auth failure, as it actually still confirms that IP connection is working.
            grep -q 'Permission denied' <<< "${sshOutput}" || ((++sshFailedCount))
        }
    done
    : "Total failures: ${sshFailedCount}"
    if ((sshFailedCount > 0)); then
        return 1
    fi
    true
}

InstallAndVerifyVirtctl || { tcMsg="virtctl installation or verification failed"; false; }
CheckVmRunningStatus || { tcMsg="One or more VMs failed the ready status check"; false; }
CheckVmIPConnectivity || { tcMsg="One or more VMs failed the IP connectivity check"; false; }

tcMsg=''
true
