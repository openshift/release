#!/bin/bash
#
# Stop CNV test VMs on the source spoke so they can be cold-migrated (powered-off).
# Patches runStrategy to Halted and waits for each VMI to be deleted.
#
set -euxo pipefail; shopt -s inherit_errexit

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # Disable xtrace: proxy-conf.sh may set HTTP_PROXY with embedded credentials.
    typeset _wasTracing=''
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    [[ "${_wasTracing}" == "true" ]] && set -x
fi

typeset -i vmCount="${P2P_HS_VM_COUNT:-${MTV_TEST_VM_COUNT:-1}}"
typeset vmPrefix="${P2P_HS_SPOKE_VM_PREFIX:-test-vm}"
typeset vmNamespace="${P2P_HS_VM_NAMESPACE:-${CNV_TEST_VM_NAMESPACE}}"
typeset spokeIndex="${P2P_HS_SPOKE_INDEX:-${CNV_TEST_VM_SPOKE_INDEX}}"
typeset explicitKubeconfig="${P2P_HS_SPOKE_KUBECONFIG:-${CNV_TEST_VM_SPOKE_KUBECONFIG}}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
typeset spokeKubeconfig=""
typeset diagDir=""

(( vmCount >= 1 )) \
    || { printf 'ERROR: VM count must be a positive integer (got: %s)\n' "${vmCount}" >&2; false; }

# VmName — return the VM name for a 1-based index.
function VmName () {
    typeset -i idx="${1:?}"; (($#)) && shift
    if (( vmCount == 1 )); then
        printf '%s' "${CNV_TEST_VM_NAME:-${vmPrefix}-1}"
    else
        printf '%s-%d' "${vmPrefix}" "${idx}"
    fi
}

# SpokeOc — run oc against the source spoke cluster.
function SpokeOc () {
    oc --kubeconfig="${spokeKubeconfig}" "$@"
}

# ResolveSpokeKubeconfig — source spoke admin kubeconfig from SHARED_DIR.
function ResolveSpokeKubeconfig () {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -n "${explicitKubeconfig}" ]]; then
        spokeKubeconfig="${explicitKubeconfig}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}"
    elif [[ "${spokeIndex}" == "1" && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
        printf 'ERROR: Spoke kubeconfig not found for index %s\n' "${spokeIndex}" >&2
        return 1
    fi
    [[ -r "${spokeKubeconfig}" ]]
}

# DumpDiagnostics — write VM state to ARTIFACT_DIR on failure.
function DumpDiagnostics () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    diagDir="${ARTIFACT_DIR}/stop-migration-vm-diagnostics"
    mkdir -p "${diagDir}"
    typeset -i i
    typeset vmName
    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        SpokeOc get "virtualmachine/${vmName}" \
            -n "${vmNamespace}" -o yaml > "${diagDir}/virtualmachine-${vmName}.yaml" 2>&1 || true
        SpokeOc get "virtualmachineinstance/${vmName}" \
            -n "${vmNamespace}" -o yaml > "${diagDir}/vmi-${vmName}.yaml" 2>&1 || true
    done
    SpokeOc get events -n "${vmNamespace}" \
        --sort-by='.lastTimestamp' > "${diagDir}/namespace-events.txt" 2>&1 || true
}

# OnError — dump diagnostics before propagating failure.
function OnError () {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# StopVms — patch runStrategy to Halted and wait for each VMI deletion.
function StopVms () {
    typeset -i i
    typeset vmName vmStatus
    typeset -i wMax=600

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        SpokeOc get "virtualmachine/${vmName}" -n "${vmNamespace}" 1>/dev/null

        SpokeOc patch "virtualmachine/${vmName}" -n "${vmNamespace}" \
            --type merge -p '{"spec":{"runStrategy":"Halted"}}' 1>/dev/null

        # VMI may already be gone if the VM was already powered off.
        SpokeOc wait "virtualmachineinstance/${vmName}" -n "${vmNamespace}" \
            --for=delete --timeout="${CNV_TEST_VM_STOP_TIMEOUT}" 1>/dev/null || true

        SECONDS=0
        vmStatus=""
        while (( SECONDS < wMax )); do
            vmStatus="$(SpokeOc get "virtualmachine/${vmName}" \
                -n "${vmNamespace}" \
                -o jsonpath='{.status.printableStatus}' || true)"
            [[ "${vmStatus}" == "Stopped" ]] && break
            printf 'INFO: Waiting for VM %s Stopped (%s/%ss): %s\n' \
                "${vmName}" "${SECONDS}" "${wMax}" "${vmStatus}" >&2
            sleep 5
        done
        [[ "${vmStatus}" == "Stopped" ]] || {
            printf 'ERROR: VM %s not Stopped (status=%s)\n' "${vmName}" "${vmStatus}" >&2
            return 1
        }
    done
}

trap - ERR

typeset -i stepRc=0
(
    trap OnError ERR

    ResolveSpokeKubeconfig
    StopVms

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            printf '%s\n' "vm_count=${vmCount}"
            printf '%s\n' "vm_namespace=${vmNamespace}"
            printf '%s\n' "vm_status=Stopped"
            typeset -i m
            for (( m = 1; m <= vmCount; m++ )); do
                printf '%s\n' "vm_name=$(VmName "${m}")"
                SpokeOc get "virtualmachine/$(VmName "${m}")" \
                    -n "${vmNamespace}" -o wide || true
            done
        } > "${ARTIFACT_DIR}/stop-migration-vm-status.txt"
    fi
    true
) || stepRc=$?

if (( stepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        printf 'WARNING: p2p-stop-migration-test-vm failed (rc=%d); not failing job (debug mode)\n' \
            "${stepRc}" >&2
    else
        exit "${stepRc}"
    fi
fi

true
