#!/bin/bash
#
# Execute two MTV cross-cluster live migrations (CCLM) per leg, in parallel.
#
# All VMs live on spoke-1.  There are two migration plans per leg:
#   Plan A : test-vm-1 … test-vm-N
#   Plan B : test-vm-(N+1) … test-vm-2N
# where N = MTV_VMS_PER_PLAN (default 5), so 10 VMs total.
#
# Leg 1 (forward):  Plan A + Plan B both migrate spoke-1 → spoke-2 simultaneously.
# Leg 2 (return):   Plan A-return + Plan B-return both migrate spoke-2 → spoke-1 simultaneously.
#
# A single polling loop per leg checks both Migration CRs until both Succeeded.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    typeset _wasTracingProxy=false
    [[ $- == *x* ]] && _wasTracingProxy=true
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    [[ "${_wasTracingProxy}" == 'true' ]] && set -x
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i migrationPollInterval="${MTV_MIGRATION_POLL_INTERVAL_SECONDS}"
typeset -i vmsPerPlan="${MTV_VMS_PER_PLAN}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"

(( vmsPerPlan >= 1 )) \
    || { printf 'ERROR: MTV_VMS_PER_PLAN must be a positive integer (got: %s)\n' "${MTV_VMS_PER_PLAN}" >&2; false; }

# Plan A uses test-vm-1 … test-vm-N; Plan B uses test-vm-(N+1) … test-vm-2N.
typeset -i planAStart=1
typeset -i planBStart=$(( vmsPerPlan + 1 ))

# Kubeconfigs — resolved at outer scope so DumpDiagnostics can use them after subshell failure.
typeset kcSpoke1=''   # source (forward) / destination (return)
typeset kcSpoke2=''   # destination (forward) / source (return)

typeset -r junitFile="${TMPDIR:-/tmp}/cclm-parallel-bidir-junit-$$.tsv"

# VmNameAt — VM name for an absolute 1-based index.
function VmNameAt () {
    typeset -i idx="${1:?}"; (($#)) && shift
    printf 'test-vm-%d' "${idx}"
    true
}

# HubOc — run oc against the ACM hub.
function HubOc () {
    oc --kubeconfig="${KUBECONFIG}" "$@"
}

# ResolveKubeconfig — return spoke kubeconfig path from SHARED_DIR by 1-based index.
function ResolveKubeconfig () {
    typeset -i idx="${1:?}"; (($#)) && shift
    typeset kc="${SHARED_DIR}/managed-cluster-kubeconfig-${idx}"
    if [[ ! -r "${kc}" && idx -eq 1 && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        kc="${SHARED_DIR}/managed-cluster-kubeconfig"
    fi
    [[ -r "${kc}" ]] \
        || { printf 'ERROR: spoke kubeconfig not found for index %d\n' "${idx}" >&2; false; }
    printf '%s' "${kc}"
    true
}

# ResolveKubeconfigs — populate kcSpoke1 and kcSpoke2.
function ResolveKubeconfigs () {
    kcSpoke1="$(ResolveKubeconfig "${MTV_SOURCE_SPOKE_INDEX}")"
    kcSpoke2="$(ResolveKubeconfig "${MTV_DEST_SPOKE_INDEX}")"
    true
}

# WaitProviderReady — gate until MTV Provider CR is Ready.
function WaitProviderReady () {
    typeset name="${1:?}"; (($#)) && shift
    HubOc wait "provider/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}" 1>/dev/null
}

# WaitMapReady — gate until a NetworkMap or StorageMap CR is Ready.
function WaitMapReady () {
    typeset kind="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    HubOc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}" 1>/dev/null
}

# PreflightProvidersAndMaps — providers and all four maps must be Ready.
function PreflightProvidersAndMaps () {
    WaitProviderReady "${MTV_SOURCE_PROVIDER}"
    WaitProviderReady "${MTV_DEST_PROVIDER}"
    WaitMapReady networkmap "${MTV_NETWORK_MAP_NAME}"
    WaitMapReady storagemap "${MTV_STORAGE_MAP_NAME}"
    WaitMapReady networkmap "${MTV_RETURN_NETWORK_MAP_NAME}"
    WaitMapReady storagemap "${MTV_RETURN_STORAGE_MAP_NAME}"
    true
}

# HasDecentralizedLiveMigrationGate — check KubeVirt feature gate on a spoke.
function HasDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift
    oc --kubeconfig="${kc}" get kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        1>/dev/null 2>&1
}

# EnsureDecentralizedLiveMigrationGate — enable CCLM gate via HCO on a spoke.
function EnsureDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift
    HasDecentralizedLiveMigrationGate "${kc}" && return 0

    typeset hcoGate
    hcoGate="$(oc --kubeconfig="${kc}" get hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
        -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' || true)"
    if [[ "${hcoGate}" != 'true' ]]; then
        oc --kubeconfig="${kc}" patch hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
            --type merge -p '{"spec":{"featureGates":{"decentralizedLiveMigration":true}}}' 1>/dev/null
    fi

    typeset -i deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        HasDecentralizedLiveMigrationGate "${kc}" && return 0
        sleep 10
    done
    false
}

# MaybeEnsureDecentralizedLiveMigration — enable CCLM gate on both spokes.
function MaybeEnsureDecentralizedLiveMigration () {
    [[ "${MTV_PLAN_TYPE}" != 'live' ]] && return 0
    [[ "${MTV_ENSURE_DECENTRALIZED_LIVE_MIGRATION}" != 'true' ]] && return 0
    EnsureDecentralizedLiveMigrationGate "${kcSpoke1}"
    EnsureDecentralizedLiveMigrationGate "${kcSpoke2}"
    true
}

# WaitSyncControllerReady — virt-synchronization-controller must be Available on a spoke.
function WaitSyncControllerReady () {
    typeset kc="${1:?}"; (($#)) && shift
    oc --kubeconfig="${kc}" wait deployment/virt-synchronization-controller \
        -n "${MTV_CNV_NAMESPACE}" --for=condition=Available --timeout="${MTV_SYNC_CONTROLLER_WAIT}" 1>/dev/null
}

# MaybeWaitForSyncControllers — both spokes must have sync controller ready.
function MaybeWaitForSyncControllers () {
    [[ "${MTV_PLAN_TYPE}" != 'live' ]] && return 0
    WaitSyncControllerReady "${kcSpoke1}"
    WaitSyncControllerReady "${kcSpoke2}"
    true
}

# PreflightCclm — ForkliftController on the hub must have FEATURE_OCP_LIVE_MIGRATION=true.
function PreflightCclm () {
    [[ "${MTV_PLAN_TYPE}" != 'live' ]] && return 0
    typeset fcGate envVal
    fcGate="$(HubOc get "forkliftcontroller/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.feature_ocp_live_migration}' || true)"
    [[ "${fcGate}" == 'true' ]]
    envVal="$(HubOc get "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
        || true)"
    [[ "${envVal}" == 'true' ]]
    true
}

# PreflightNoGlobalnet — Globalnet breaks pod-IP CCLM sync routing.
function PreflightNoGlobalnet () {
    typeset kc="${1:?}"; (($#)) && shift
    ! oc --kubeconfig="${kc}" get daemonset submariner-globalnet \
        -n submariner-operator 1>/dev/null 2>&1
}

# MaybePreflightNoGlobalnet — both spokes must not run Globalnet.
function MaybePreflightNoGlobalnet () {
    [[ "${MTV_PLAN_TYPE}" != 'live' ]] && return 0
    PreflightNoGlobalnet "${kcSpoke1}"
    PreflightNoGlobalnet "${kcSpoke2}"
    true
}

# RefreshAndWaitProviders — re-scan provider inventories and wait Ready.
function RefreshAndWaitProviders () {
    [[ "${MTV_PLAN_TYPE}" != 'live' ]] && return 0
    typeset ts
    ts="$(date -u +%s)"
    HubOc annotate "provider/${MTV_SOURCE_PROVIDER}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite 1>/dev/null
    HubOc annotate "provider/${MTV_DEST_PROVIDER}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite 1>/dev/null
    HubOc wait "provider/${MTV_SOURCE_PROVIDER}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}" 1>/dev/null
    HubOc wait "provider/${MTV_DEST_PROVIDER}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}" 1>/dev/null
    true
}

# PreflightSourceVmsRunning — VMs in a given index range must exist and be Running on a spoke.
function PreflightSourceVmsRunning () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset -i startIdx="${1:?}"; (($#)) && shift
    typeset -i count="${1:?}"; (($#)) && shift
    typeset label="${1:?}"; (($#)) && shift
    typeset -i i
    typeset vmName phase

    for (( i = startIdx; i < startIdx + count; i++ )); do
        vmName="$(VmNameAt "${i}")"
        oc --kubeconfig="${kc}" get "virtualmachine/${vmName}" \
            -n "${MTV_TEST_VM_NAMESPACE}" 1>/dev/null
        if [[ "${MTV_PLAN_TYPE}" == 'live' ]]; then
            phase="$(oc --kubeconfig="${kc}" get "virtualmachineinstance/${vmName}" \
                -n "${MTV_TEST_VM_NAMESPACE}" -o jsonpath='{.status.phase}' || true)"
            [[ "${phase}" == 'Running' ]] \
                || { printf 'ERROR: [%s] VMI %s not Running (phase=%s)\n' \
                    "${label}" "${vmName}" "${phase}" >&2; false; }
        fi
    done
    true
}

# ApplyPlan — create or update an MTV Plan CR for a contiguous range of VMs.
function ApplyPlan () {
    typeset planName="${1:?}"; (($#)) && shift
    typeset srcProvider="${1:?}"; (($#)) && shift
    typeset dstProvider="${1:?}"; (($#)) && shift
    typeset netMap="${1:?}"; (($#)) && shift
    typeset storMap="${1:?}"; (($#)) && shift
    typeset -i vmStart="${1:?}"; (($#)) && shift   # 1-based inclusive start index
    typeset -i vmEnd="${1:?}"; (($#)) && shift     # 1-based inclusive end index

    typeset -i i
    typeset vmsJson='[]'
    for (( i = vmStart; i <= vmEnd; i++ )); do
        vmsJson="$(jq -cn \
            --argjson vms "${vmsJson}" \
            --arg name "$(VmNameAt "${i}")" \
            --arg ns "${MTV_TEST_VM_NAMESPACE}" \
            '$vms + [{"name": $name, "namespace": $ns}]')"
    done

    jq -cn \
        --arg planName    "${planName}" \
        --arg ns          "${MTV_NAMESPACE}" \
        --arg srcProvider "${srcProvider}" \
        --arg dstProvider "${dstProvider}" \
        --arg tgtNs       "${MTV_TEST_VM_NAMESPACE}" \
        --arg netMap      "${netMap}" \
        --arg storMap     "${storMap}" \
        --argjson vms     "${vmsJson}" \
        --arg planType    "${MTV_PLAN_TYPE}" \
        '{
            "apiVersion": "forklift.konveyor.io/v1beta1",
            "kind": "Plan",
            "metadata": {"name": $planName, "namespace": $ns},
            "spec": {
                "provider": {
                    "source":      {"name": $srcProvider, "namespace": $ns},
                    "destination": {"name": $dstProvider, "namespace": $ns}
                },
                "targetNamespace": $tgtNs,
                "map": {
                    "network": {"name": $netMap, "namespace": $ns},
                    "storage": {"name": $storMap, "namespace": $ns}
                },
                "vms":  $vms,
                "type": $planType
            }
        }' \
    | { HubOc create -f - --dry-run=client -o json --save-config | jq -c .; } \
    | HubOc apply -f -
    true
}

# WaitPlanReady — gate until an MTV Plan CR is Ready.
function WaitPlanReady () {
    typeset planName="${1:?}"; (($#)) && shift
    HubOc wait "plan/${planName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}" 1>/dev/null
}

# ApplyMigration — create Migration CR referencing a Plan.
function ApplyMigration () {
    typeset migName="${1:?}"; (($#)) && shift
    typeset planName="${1:?}"; (($#)) && shift

    jq -cn \
        --arg migName  "${migName}" \
        --arg ns       "${MTV_NAMESPACE}" \
        --arg planName "${planName}" \
        '{
            "apiVersion": "forklift.konveyor.io/v1beta1",
            "kind": "Migration",
            "metadata": {"name": $migName, "namespace": $ns},
            "spec": {"plan": {"name": $planName, "namespace": $ns}}
        }' \
    | { HubOc create -f - --dry-run=client -o yaml --save-config; } \
    | HubOc apply -f -
    true
}

# ParseOcWaitDurationSeconds — convert duration string (2h, 15m, 30s) to seconds.
function ParseOcWaitDurationSeconds () {
    typeset duration="${1:?}"; (($#)) && shift
    if [[ "${duration}" =~ ^([0-9]+)h$ ]]; then
        printf '%d\n' $(( BASH_REMATCH[1] * 3600 ))
    elif [[ "${duration}" =~ ^([0-9]+)m$ ]]; then
        printf '%d\n' $(( BASH_REMATCH[1] * 60 ))
    elif [[ "${duration}" =~ ^([0-9]+)s$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%d\n' 21600
    fi
}

# MigrationConditionStatus — return "True"/"False"/"" for a condition type on a Migration CR.
function MigrationConditionStatus () {
    typeset migName="${1:?}"; (($#)) && shift
    typeset condType="${1:?}"; (($#)) && shift
    HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
        -o jsonpath="{.status.conditions[?(@.type==\"${condType}\")].status}" || true
}

# WaitBothMigrationsComplete — poll two Migration CRs in a single loop.
# Returns 0 only when both Succeeded; returns 1 if either Failed or timeout.
function WaitBothMigrationsComplete () {
    typeset migNameA="${1:?}"; (($#)) && shift
    typeset migNameB="${1:?}"; (($#)) && shift
    typeset legLabel="${1:?}"; (($#)) && shift

    typeset -i deadline
    deadline=$((SECONDS + $(ParseOcWaitDurationSeconds "${MTV_MIGRATION_TIMEOUT}")))

    typeset aDone='false' bDone='false' aStatus='' bStatus=''

    while (( SECONDS < deadline )); do
        if [[ "${aDone}" != 'true' ]]; then
            if [[ "$(MigrationConditionStatus "${migNameA}" 'Succeeded')" == 'True' ]]; then
                aStatus='Succeeded'; aDone='true'
            elif [[ "$(MigrationConditionStatus "${migNameA}" 'Failed')" == 'True' ]]; then
                aStatus='Failed'; aDone='true'
            fi
        fi

        if [[ "${bDone}" != 'true' ]]; then
            if [[ "$(MigrationConditionStatus "${migNameB}" 'Succeeded')" == 'True' ]]; then
                bStatus='Succeeded'; bDone='true'
            elif [[ "$(MigrationConditionStatus "${migNameB}" 'Failed')" == 'True' ]]; then
                bStatus='Failed'; bDone='true'
            fi
        fi

        if [[ "${aDone}" == 'true' && "${bDone}" == 'true' ]]; then
            : "[${legLabel}] Both migrations done — A=${aStatus}, B=${bStatus}"
            [[ "${aStatus}" == 'Succeeded' && "${bStatus}" == 'Succeeded' ]]
            return 0
        fi

        : "[${legLabel}] Parallel migrations in progress — A=${aStatus:-Running}, B=${bStatus:-Running} (${SECONDS}/${deadline}s)"
        sleep "${migrationPollInterval}"
    done

    printf 'ERROR: [%s] Timeout waiting for parallel migrations (A=%s, B=%s)\n' \
        "${legLabel}" "${aStatus:-Running}" "${bStatus:-Running}" >&2
    false
}

# VerifyVmsRunning — VMs in an index range must be Running on a spoke after migration.
function VerifyVmsRunning () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset -i startIdx="${1:?}"; (($#)) && shift
    typeset -i count="${1:?}"; (($#)) && shift
    typeset label="${1:?}"; (($#)) && shift
    typeset -i i
    typeset vmName phase

    for (( i = startIdx; i < startIdx + count; i++ )); do
        vmName="$(VmNameAt "${i}")"
        phase="$(oc --kubeconfig="${kc}" get "virtualmachineinstance/${vmName}" \
            -n "${MTV_TEST_VM_NAMESPACE}" -o jsonpath='{.status.phase}' || true)"
        [[ "${phase}" == 'Running' ]] \
            || { printf 'ERROR: [%s] VMI %s not Running on destination (phase=%s)\n' \
                "${label}" "${vmName}" "${phase}" >&2; false; }
    done
    true
}

# CleanupStaleVmsOnSpoke — remove stopped VMs/DVs left by the forward leg on spoke-1.
# MTV leaves source VMs in Stopped state after a successful live migration; they must
# be removed before spoke-1 can receive the same VMs in the return leg.
function CleanupStaleVmsOnSpoke () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset -i startIdx="${1:?}"; (($#)) && shift
    typeset -i count="${1:?}"; (($#)) && shift
    typeset label="${1:?}"; (($#)) && shift
    typeset -i i
    typeset vmName dvName

    for (( i = startIdx; i < startIdx + count; i++ )); do
        vmName="$(VmNameAt "${i}")"
        dvName="${vmName}-rootdisk"
        oc --kubeconfig="${kc}" delete "virtualmachine/${vmName}" \
            -n "${MTV_TEST_VM_NAMESPACE}" --ignore-not-found=true --timeout=2m 1>/dev/null || true
        oc --kubeconfig="${kc}" delete "datavolume/${dvName}" \
            -n "${MTV_TEST_VM_NAMESPACE}" --ignore-not-found=true --timeout=2m 1>/dev/null || true
        oc --kubeconfig="${kc}" delete "pvc/${dvName}" \
            -n "${MTV_TEST_VM_NAMESPACE}" --ignore-not-found=true --timeout=2m 1>/dev/null || true
        : "[${label}] cleaned stale resources for ${vmName}"
    done
    true
}

# DumpDiagnostics — collect MTV and VM state for all four plans.
function DumpDiagnostics () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/mtv-parallel-bidir-diagnostics"
    mkdir -p "${diagDir}"

    HubOc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${diagDir}/hub-mtv-resources.txt" 2>&1 || true
    HubOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/hub-mtv-events.txt" 2>&1 || true
    HubOc describe \
        "plan/${MTV_PLAN_A_NAME}" "plan/${MTV_PLAN_B_NAME}" \
        "plan/${MTV_PLAN_A_RETURN_NAME}" "plan/${MTV_PLAN_B_RETURN_NAME}" \
        -n "${MTV_NAMESPACE}" \
        > "${diagDir}/plans-describe.txt" 2>&1 || true

    if [[ -n "${kcSpoke1}" && -r "${kcSpoke1}" ]]; then
        oc --kubeconfig="${kcSpoke1}" get pods -n "${MTV_CNV_NAMESPACE}" -o wide \
            > "${diagDir}/spoke1-cnv-pods.txt" 2>&1 || true
    fi
    if [[ -n "${kcSpoke2}" && -r "${kcSpoke2}" ]]; then
        oc --kubeconfig="${kcSpoke2}" get pods -n "${MTV_CNV_NAMESPACE}" -o wide \
            > "${diagDir}/spoke2-cnv-pods.txt" 2>&1 || true
    fi
    true
}

# OnError — dump diagnostics and propagate failure.
function OnError () {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# JStep — run a function, record PASS/FAIL in junitFile, propagate exit code.
function JStep () {
    typeset name="${1:?}"; shift
    typeset -i t0=$SECONDS rc=0
    "$@" || rc=$?
    typeset -i elapsed=$(( SECONDS - t0 ))
    if (( rc == 0 )); then
        printf 'PASS\t%s\t%d\t\n' "${name}" "${elapsed}" >> "${junitFile}"
    else
        printf 'FAIL\t%s\t%d\tFailed (rc=%d); see mtv-parallel-bidir-diagnostics/\n' \
            "${name}" "${elapsed}" "${rc}" >> "${junitFile}"
    fi
    return "${rc}"
}

# XmlEscape — replace XML-special characters.
function XmlEscape () {
    typeset s="${1}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

# WriteJunit — emit JUnit XML from accumulated records.
function WriteJunit () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    [[ -f "${junitFile}" ]] || return 0

    typeset xmlFile="${ARTIFACT_DIR}/junit_cclm_parallel_bidir_migration.xml"
    mkdir -p "${ARTIFACT_DIR}"

    typeset -i total=0 failures=0 totalTime=0
    typeset status name elapsed failMsg
    while IFS=$'\t' read -r status name elapsed failMsg; do
        (( total++ )) || true
        (( totalTime += elapsed )) || true
        [[ "${status}" == 'FAIL' ]] && (( failures++ )) || true
    done < "${junitFile}"

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuite name="cclm-parallel-bidir-migration" tests="%d" failures="%d" errors="0" skipped="0" time="%d">\n' \
            "${total}" "${failures}" "${totalTime}"
        while IFS=$'\t' read -r status name elapsed failMsg; do
            typeset escapedName; escapedName="$(XmlEscape "${name}")"
            printf '  <testcase name="%s" classname="cclm-parallel-bidir-migration" time="%d">\n' \
                "${escapedName}" "${elapsed}"
            if [[ "${status}" == 'FAIL' ]]; then
                typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
                printf '    <failure message="%s">%s</failure>\n' "${escapedMsg}" "${escapedMsg}"
            fi
            printf '  </testcase>\n'
        done < "${junitFile}"
        printf '</testsuite>\n'
    } > "${xmlFile}"

    : "JUnit XML -> ${xmlFile} (${total} tests, ${failures} failures, ${totalTime}s)"
    rm -f "${junitFile}"
    true
}

# ---- Main ----

# Resolve at outer scope so DumpDiagnostics has kubeconfigs after subshell failure.
[[ -n "${SHARED_DIR}" ]] && ResolveKubeconfigs || true

trap - ERR

typeset -i cclmStepRc=0
(
    trap OnError ERR

    ResolveKubeconfigs

    [[ "${MTV_PLAN_TYPE}" == 'live' || "${MTV_PLAN_TYPE}" == 'cold' ]]

    typeset -i planAEnd=$(( planAStart + vmsPerPlan - 1 ))   # 1..5  (default)
    typeset -i planBEnd=$(( planBStart + vmsPerPlan - 1 ))   # 6..10 (default)

    # ---- Phase 1: Preflight ----
    JStep 'Preflight: Providers and Maps Ready'           PreflightProvidersAndMaps
    JStep 'Preflight: DecentralizedLiveMigration Gates'   MaybeEnsureDecentralizedLiveMigration
    JStep 'Preflight: Sync Controllers Available'         MaybeWaitForSyncControllers
    JStep 'Preflight: MTV CCLM Feature Gate Active'       PreflightCclm
    JStep 'Preflight: Submariner No Globalnet'            MaybePreflightNoGlobalnet
    JStep 'Preflight: Provider Inventory Refresh'         RefreshAndWaitProviders
    JStep "Preflight: Plan A Source VMs Running (spoke-1, vm ${planAStart}-${planAEnd})" \
        PreflightSourceVmsRunning "${kcSpoke1}" "${planAStart}" "${vmsPerPlan}" 'Plan-A'
    JStep "Preflight: Plan B Source VMs Running (spoke-1, vm ${planBStart}-${planBEnd})" \
        PreflightSourceVmsRunning "${kcSpoke1}" "${planBStart}" "${vmsPerPlan}" 'Plan-B'

    # ---- Phase 2: Parallel forward migration (spoke-1 → spoke-2) ----
    JStep "Leg1 Plan A: Apply Plan (vm ${planAStart}-${planAEnd}, spoke-1 → spoke-2)" \
        ApplyPlan "${MTV_PLAN_A_NAME}" "${MTV_SOURCE_PROVIDER}" "${MTV_DEST_PROVIDER}" \
            "${MTV_NETWORK_MAP_NAME}" "${MTV_STORAGE_MAP_NAME}" "${planAStart}" "${planAEnd}"
    JStep "Leg1 Plan B: Apply Plan (vm ${planBStart}-${planBEnd}, spoke-1 → spoke-2)" \
        ApplyPlan "${MTV_PLAN_B_NAME}" "${MTV_SOURCE_PROVIDER}" "${MTV_DEST_PROVIDER}" \
            "${MTV_NETWORK_MAP_NAME}" "${MTV_STORAGE_MAP_NAME}" "${planBStart}" "${planBEnd}"
    JStep 'Leg1 Plan A: Plan Ready'   WaitPlanReady "${MTV_PLAN_A_NAME}"
    JStep 'Leg1 Plan B: Plan Ready'   WaitPlanReady "${MTV_PLAN_B_NAME}"
    # Submit both migrations back-to-back — MTV executes them concurrently.
    JStep 'Leg1 Plan A: Apply Migration'              ApplyMigration "${MTV_MIGRATION_A_NAME}" "${MTV_PLAN_A_NAME}"
    JStep 'Leg1 Plan B: Apply Migration'              ApplyMigration "${MTV_MIGRATION_B_NAME}" "${MTV_PLAN_B_NAME}"
    JStep 'Leg1 Plan A+B: Both Migrations Succeeded'  \
        WaitBothMigrationsComplete "${MTV_MIGRATION_A_NAME}" "${MTV_MIGRATION_B_NAME}" 'Leg1-Forward'

    # ---- Phase 3: Verify forward ----
    JStep "Leg1 Plan A: Destination VMIs Running (spoke-2, vm ${planAStart}-${planAEnd})" \
        VerifyVmsRunning "${kcSpoke2}" "${planAStart}" "${vmsPerPlan}" 'Leg1-Plan-A'
    JStep "Leg1 Plan B: Destination VMIs Running (spoke-2, vm ${planBStart}-${planBEnd})" \
        VerifyVmsRunning "${kcSpoke2}" "${planBStart}" "${vmsPerPlan}" 'Leg1-Plan-B'

    # ---- Phase 4: Cleanup stale source VMs on spoke-1 before return leg ----
    # MTV leaves source VMs in Stopped state after a successful live migration.
    # spoke-1 is the destination of the return leg; stale stopped VMs must be removed first.
    JStep "Leg2 Pre-return: Cleanup stale VMs on spoke-1 (vm ${planAStart}-${planAEnd})" \
        CleanupStaleVmsOnSpoke "${kcSpoke1}" "${planAStart}" "${vmsPerPlan}" 'Leg2-Plan-A-return'
    JStep "Leg2 Pre-return: Cleanup stale VMs on spoke-1 (vm ${planBStart}-${planBEnd})" \
        CleanupStaleVmsOnSpoke "${kcSpoke1}" "${planBStart}" "${vmsPerPlan}" 'Leg2-Plan-B-return'

    # ---- Phase 5: Parallel return migration (spoke-2 → spoke-1) ----
    JStep "Leg2 Plan A-return: Apply Plan (vm ${planAStart}-${planAEnd}, spoke-2 → spoke-1)" \
        ApplyPlan "${MTV_PLAN_A_RETURN_NAME}" "${MTV_DEST_PROVIDER}" "${MTV_SOURCE_PROVIDER}" \
            "${MTV_RETURN_NETWORK_MAP_NAME}" "${MTV_RETURN_STORAGE_MAP_NAME}" "${planAStart}" "${planAEnd}"
    JStep "Leg2 Plan B-return: Apply Plan (vm ${planBStart}-${planBEnd}, spoke-2 → spoke-1)" \
        ApplyPlan "${MTV_PLAN_B_RETURN_NAME}" "${MTV_DEST_PROVIDER}" "${MTV_SOURCE_PROVIDER}" \
            "${MTV_RETURN_NETWORK_MAP_NAME}" "${MTV_RETURN_STORAGE_MAP_NAME}" "${planBStart}" "${planBEnd}"
    JStep 'Leg2 Plan A-return: Plan Ready'  WaitPlanReady "${MTV_PLAN_A_RETURN_NAME}"
    JStep 'Leg2 Plan B-return: Plan Ready'  WaitPlanReady "${MTV_PLAN_B_RETURN_NAME}"
    JStep 'Leg2 Plan A-return: Apply Migration' \
        ApplyMigration "${MTV_MIGRATION_A_RETURN_NAME}" "${MTV_PLAN_A_RETURN_NAME}"
    JStep 'Leg2 Plan B-return: Apply Migration' \
        ApplyMigration "${MTV_MIGRATION_B_RETURN_NAME}" "${MTV_PLAN_B_RETURN_NAME}"
    JStep 'Leg2 Plan A+B-return: Both Migrations Succeeded' \
        WaitBothMigrationsComplete "${MTV_MIGRATION_A_RETURN_NAME}" "${MTV_MIGRATION_B_RETURN_NAME}" 'Leg2-Return'

    # ---- Phase 6: Verify return ----
    JStep "Leg2 Plan A-return: Destination VMIs Running (spoke-1, vm ${planAStart}-${planAEnd})" \
        VerifyVmsRunning "${kcSpoke1}" "${planAStart}" "${vmsPerPlan}" 'Leg2-Plan-A-return'
    JStep "Leg2 Plan B-return: Destination VMIs Running (spoke-1, vm ${planBStart}-${planBEnd})" \
        VerifyVmsRunning "${kcSpoke1}" "${planBStart}" "${vmsPerPlan}" 'Leg2-Plan-B-return'

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            HubOc get \
                "plan/${MTV_PLAN_A_NAME}" "plan/${MTV_PLAN_B_NAME}" \
                "plan/${MTV_PLAN_A_RETURN_NAME}" "plan/${MTV_PLAN_B_RETURN_NAME}" \
                "migration/${MTV_MIGRATION_A_NAME}" "migration/${MTV_MIGRATION_B_NAME}" \
                "migration/${MTV_MIGRATION_A_RETURN_NAME}" "migration/${MTV_MIGRATION_B_RETURN_NAME}" \
                -n "${MTV_NAMESPACE}" -o wide
        } > "${ARTIFACT_DIR}/mtv-parallel-bidir-status.txt" 2>&1 || true
    fi
    true
) || cclmStepRc=$?

WriteJunit

if (( cclmStepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == 'true' ]]; then
        printf 'WARNING: p2p-mtv-execute-parallel-bidir-migration failed (rc=%d); not failing job (debug mode)\n' \
            "${cclmStepRc}" >&2
    else
        exit "${cclmStepRc}"
    fi
fi

true
