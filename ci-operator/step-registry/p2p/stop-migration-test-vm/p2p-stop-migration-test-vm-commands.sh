#!/bin/bash
#
# Stop the CNV test VM on the source spoke to prepare it for cold migration.
# Patches runStrategy to Halted and waits for the VMI to be deleted.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

typeset -i spokeIndex="${CNV_TEST_VM_SPOKE_INDEX}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
typeset spokeKubeconfig=""

# SpokeOc — run oc against the source spoke cluster.
SpokeOc() {
    oc --kubeconfig="${spokeKubeconfig}" "$@"
}

# ResolveSpokeKubeconfig — source spoke admin kubeconfig from SHARED_DIR.
ResolveSpokeKubeconfig() {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -n "${CNV_TEST_VM_SPOKE_KUBECONFIG}" ]]; then
        spokeKubeconfig="${CNV_TEST_VM_SPOKE_KUBECONFIG}"
    else
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}"
        if [[ ! -r "${spokeKubeconfig}" && spokeIndex -eq 1 && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
            spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
        fi
    fi

    [[ -r "${spokeKubeconfig}" ]]
}

# DumpDiagnostics — write VM state to ARTIFACT_DIR on failure.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/stop-migration-vm-diagnostics"
    mkdir -p "${diagDir}"
    SpokeOc get "virtualmachine/${CNV_TEST_VM_NAME}" \
        -n "${CNV_TEST_VM_NAMESPACE}" -o yaml > "${diagDir}/virtualmachine.yaml" 2>&1 || true
    SpokeOc get "virtualmachineinstance/${CNV_TEST_VM_NAME}" \
        -n "${CNV_TEST_VM_NAMESPACE}" -o yaml > "${diagDir}/vmi.yaml" 2>&1 || true
    SpokeOc get events -n "${CNV_TEST_VM_NAMESPACE}" \
        --sort-by='.lastTimestamp' > "${diagDir}/namespace-events.txt" 2>&1 || true
}

# OnError — dump diagnostics before propagating failure.
OnError() {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# StopVm — patch runStrategy to Halted and wait for VMI deletion.
StopVm() {
    # Verify VM exists before attempting to stop it.
    SpokeOc get "virtualmachine/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" 1>/dev/null

    SpokeOc patch "virtualmachine/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" \
        --type merge -p '{"spec":{"runStrategy":"Halted"}}' 1>/dev/null

    # Wait for VMI to be deleted (VM powered off).
    SpokeOc wait "virtualmachineinstance/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" \
        --for=delete --timeout="${CNV_TEST_VM_STOP_TIMEOUT}" 1>/dev/null || true

    # Confirm VM printableStatus is Stopped.
    (
        typeset vmStatus=""
        SECONDS=0
        typeset -i wMax=120
        while (( SECONDS < wMax )); do
            vmStatus="$(SpokeOc get "virtualmachine/${CNV_TEST_VM_NAME}" \
                -n "${CNV_TEST_VM_NAMESPACE}" \
                -o jsonpath='{.status.printableStatus}' || true)"
            [[ "${vmStatus}" == "Stopped" ]] && exit 0
            : "Waiting for VM Stopped status (${SECONDS}/${wMax}s): ${vmStatus}"
            sleep 5
        done
        : "Timed out waiting for VM ${CNV_TEST_VM_NAME} to reach Stopped status (last: ${vmStatus})" >&2
        exit 1
    )
}

trap - ERR

typeset -i stepRc=0
(
    trap OnError ERR

    ResolveSpokeKubeconfig
    StopVm

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            printf '%s\n' "vm_name=${CNV_TEST_VM_NAME}"
            printf '%s\n' "vm_namespace=${CNV_TEST_VM_NAMESPACE}"
            printf '%s\n' "vm_status=Stopped"
            printf '%s\n' "spoke_kubeconfig=${spokeKubeconfig}"
            SpokeOc get "virtualmachine/${CNV_TEST_VM_NAME}" \
                -n "${CNV_TEST_VM_NAMESPACE}" -o wide
        } > "${ARTIFACT_DIR}/stop-migration-vm-status.txt"
    fi
    true
) || stepRc=$?

if (( stepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-stop-migration-test-vm failed (rc=${stepRc}); not failing job (debug mode)"
    else
        exit "${stepRc}"
    fi
fi

true
