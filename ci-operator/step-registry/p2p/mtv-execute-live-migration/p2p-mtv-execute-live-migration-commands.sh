#!/bin/bash
#
# Execute MTV cross-cluster live migration (CCLM) from source spoke to destination spoke on the hub.
#
# When MTV_TEST_VM_COUNT=1 behaves identically to the original single-VM path.
# When MTV_TEST_VM_COUNT>1 all VMs (test-vm-1 … test-vm-N) are migrated in a single
# MTV Plan.  All VMs are verified Running on the destination.  Port 22 is probed on
# each migrated VM when MTV_VM_SSH_VERIFY=true (best-effort; failure is recorded in
# JUnit but does not block migration success).
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
    [[ "${_wasTracingProxy}" == "true" ]] && set -x
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i migrationPollInterval="${MTV_MIGRATION_POLL_INTERVAL_SECONDS}"
typeset -i sourceSpokeIndex="${MTV_SOURCE_SPOKE_INDEX}"
typeset -i destSpokeIndex="${MTV_DEST_SPOKE_INDEX}"
typeset -i syncStuckMinutes="${MTV_SYNC_STUCK_MINUTES}"
typeset -i syncPhaseStartedAt=0
typeset -i vmCount="${MTV_TEST_VM_COUNT}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
typeset vmSshVerify="${MTV_VM_SSH_VERIFY}"

(( vmCount >= 1 )) \
    || { printf 'ERROR: MTV_TEST_VM_COUNT must be a positive integer (got: %s)\n' "${MTV_TEST_VM_COUNT}" >&2; false; }

# Temp file accumulating tab-separated JUnit records (PASS/FAIL/WARN\tname\telapsed\t[msg]).
typeset -r junitFile="${TMPDIR:-/tmp}/cclm-junit-$$.tsv"

typeset sourceKubeconfig="${MTV_SOURCE_SPOKE_KUBECONFIG}"
typeset destKubeconfig="${MTV_DEST_SPOKE_KUBECONFIG}"
typeset targetNs="${MTV_TEST_VM_TARGET_NAMESPACE}"
typeset diagDir=""

# VmName — return the VM name for a 1-based index.
# When vmCount=1 returns MTV_TEST_VM_NAME unchanged (backward compat).
function VmName () {
    typeset -i idx="${1:?}"; (($#)) && shift
    if (( vmCount == 1 )); then
        printf '%s' "${MTV_TEST_VM_NAME}"
    else
        printf 'test-vm-%d' "${idx}"
    fi
    true
}

# HubOc — run oc against the ACM hub.
function HubOc () {
    oc --kubeconfig="${KUBECONFIG}" "$@"
}

# SourceOc — run oc against the source spoke.
function SourceOc () {
    oc --kubeconfig="${sourceKubeconfig}" "$@"
}

# DestOc — run oc against the destination spoke.
function DestOc () {
    oc --kubeconfig="${destKubeconfig}" "$@"
}

# ResolveSpokeKubeconfigs — source and destination spoke admin kubeconfigs.
function ResolveSpokeKubeconfigs () {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -z "${sourceKubeconfig}" ]]; then
        if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}" ]]; then
            sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}"
        elif (( sourceSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
            sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
        else
            printf 'ERROR: Source spoke kubeconfig not found for index %d\n' "${sourceSpokeIndex}" >&2
            false
        fi
    fi
    [[ -r "${sourceKubeconfig}" ]]

    if [[ -z "${destKubeconfig}" ]]; then
        [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}" ]]
        destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}"
    fi
    [[ -r "${destKubeconfig}" ]]
}

# DumpDiagnostics — write MTV and VM state to ARTIFACT_DIR on failure.
function DumpDiagnostics () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    diagDir="${ARTIFACT_DIR}/mtv-live-migration-diagnostics"
    mkdir -p "${diagDir}"
    HubOc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${diagDir}/hub-mtv-resources.txt" 2>&1 || true
    HubOc describe "plan/${MTV_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
        > "${diagDir}/plan-describe.txt" 2>&1 || true
    HubOc describe "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
        > "${diagDir}/migration-describe.txt" 2>&1 || true
    HubOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/hub-mtv-events.txt" 2>&1 || true

    typeset -i k
    for (( k = 1; k <= vmCount; k++ )); do
        typeset vn
        vn="$(VmName "${k}")"
        SourceOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
            -n "${MTV_TEST_VM_NAMESPACE}" -o wide > "${diagDir}/source-vm-${vn}.txt" 2>&1 || true
        DestOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
            -n "${targetNs}" -o wide > "${diagDir}/dest-vm-${vn}.txt" 2>&1 || true
        SourceOc get vmim -n "${MTV_TEST_VM_NAMESPACE}" -o yaml \
            > "${diagDir}/source-vmim-${vn}.yaml" 2>&1 || true
        DestOc get vmim -n "${targetNs}" -o yaml \
            > "${diagDir}/dest-vmim-${vn}.yaml" 2>&1 || true
    done
    DestOc get datavolume,pvc,pods -n "${targetNs}" \
        > "${diagDir}/dest-storage.txt" 2>&1 || true
    SourceOc get pods -n "${MTV_CNV_NAMESPACE}" -o wide \
        > "${diagDir}/source-cnv-pods.txt" 2>&1 || true
    DestOc get pods -n "${MTV_CNV_NAMESPACE}" -o wide \
        > "${diagDir}/dest-cnv-pods.txt" 2>&1 || true
    SourceOc logs -n "${MTV_CNV_NAMESPACE}" \
        -l kubevirt.io=virt-controller --tail=100 \
        > "${diagDir}/source-virt-controller.log" 2>&1 || true
    DestOc logs -n "${MTV_CNV_NAMESPACE}" \
        -l kubevirt.io=virt-controller --tail=100 \
        > "${diagDir}/dest-virt-controller.log" 2>&1 || true
}

# OnError — dump diagnostics before propagating failure.
function OnError () {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# WaitProviderReady — gate until MTV Provider is Ready.
function WaitProviderReady () {
    typeset providerName="${1:?}"; (($#)) && shift
    HubOc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# WaitMapReady — gate until NetworkMap or StorageMap is Ready.
function WaitMapReady () {
    typeset kind="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    HubOc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# PreflightSourceVm — all source VMs must exist and be Running (live plan).
function PreflightSourceVm () {
    typeset -i i
    typeset vmName phase

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        SourceOc get "virtualmachine/${vmName}" -n "${MTV_TEST_VM_NAMESPACE}" 1>/dev/null

        phase="$(SourceOc get "virtualmachineinstance/${vmName}" -n "${MTV_TEST_VM_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"

        if [[ "${MTV_PLAN_TYPE}" == "live" ]]; then
            [[ "${phase}" == "Running" ]] \
                || { : "VMI ${vmName} not Running on source (phase=${phase})"; false; }
        fi
    done
}

# GetVmRootDiskStorageClass — resolve root disk StorageClass from source VM.
function GetVmRootDiskStorageClass () {
    typeset vmName="${1:?}"; (($#)) && shift
    typeset dvName pvcName scName

    dvName="$(SourceOc get "virtualmachine/${vmName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o json |
        jq -r 'first(.spec.template.spec.volumes[]?.dataVolume.name // empty) // ""')"
    [[ -z "${dvName}" ]] && dvName="${vmName}-rootdisk"

    pvcName="$(SourceOc get "datavolume/${dvName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o jsonpath='{.status.claimName}' || true)"
    [[ -z "${pvcName}" ]] && pvcName="${dvName}"

    scName="$(SourceOc get "persistentvolumeclaim/${pvcName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o jsonpath='{.spec.storageClassName}' || true)"
    [[ -n "${scName}" ]] && printf '%s' "${scName}" && return 0

    SourceOc get pvc -n "${MTV_TEST_VM_NAMESPACE}" -o json |
        jq -r --arg pvc "${pvcName}" '
            (first(.items[] | select(.metadata.name == $pvc) | .spec.storageClassName) //
             first(.items[].spec.storageClassName) //
             "") // ""
        '
}

# PreflightVmStorageMapped — all source VM root disks must appear in StorageMap.
function PreflightVmStorageMapped () {
    typeset -i i
    typeset vmName vmSc scUid mapJson mapped

    mapJson="$(HubOc get "storagemap/${MTV_STORAGE_MAP_NAME}" -n "${MTV_NAMESPACE}" -o json)"

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        vmSc="$(GetVmRootDiskStorageClass "${vmName}")"
        [[ -n "${vmSc}" ]] || { : "No StorageClass found for ${vmName}"; false; }

        scUid="$(SourceOc get "storageclass/${vmSc}" -o jsonpath='{.metadata.uid}' || true)"
        mapped="$(jq -r --arg sc "${vmSc}" --arg uid "${scUid}" \
            '[.spec.map[]? | select(.source.name == $sc or (.source.id != null and .source.id == $uid))] | length > 0' \
            <<<"${mapJson}")"
        [[ "${mapped}" == "true" ]] \
            || { : "VM ${vmName} root disk StorageClass ${vmSc} not mapped in ${MTV_STORAGE_MAP_NAME}"; false; }
    done
}

# PreflightHub — providers and maps must be Ready before Plan creation.
function PreflightHub () {
    WaitProviderReady "${MTV_SOURCE_PROVIDER}"
    WaitProviderReady "${MTV_DESTINATION_PROVIDER}"
    WaitMapReady networkmap "${MTV_NETWORK_MAP_NAME}"
    WaitMapReady storagemap "${MTV_STORAGE_MAP_NAME}"
}

# HasDecentralizedLiveMigrationGate — KubeVirt must list DecentralizedLiveMigration.
function HasDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift

    oc --kubeconfig="${kc}" get kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        > /dev/null
}

# EnsureDecentralizedLiveMigrationGate — enable CCLM via HCO featureGates.
function EnsureDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset hcoGate

    HasDecentralizedLiveMigrationGate "${kc}" && return 0

    hcoGate="$(oc --kubeconfig="${kc}" get hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
        -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' || true)"
    if [[ "${hcoGate}" != "true" ]]; then
        oc --kubeconfig="${kc}" patch hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
            --type merge -p '{"spec":{"featureGates":{"decentralizedLiveMigration":true}}}'
    fi

    WaitForDecentralizedLiveMigrationGate "${kc}" && return 0

    oc --kubeconfig="${kc}" patch kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" \
        --type merge -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates":["DecentralizedLiveMigration"]}}}}'

    WaitForDecentralizedLiveMigrationGate "${kc}"
}

# WaitForDecentralizedLiveMigrationGate — poll KubeVirt until gate appears.
function WaitForDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset -i deadline=$((SECONDS + 600))

    while (( SECONDS < deadline )); do
        HasDecentralizedLiveMigrationGate "${kc}" && return 0
        sleep 10
    done
    false
}

# MaybeEnsureDecentralizedLiveMigration — enable CCLM gate on both spokes.
function MaybeEnsureDecentralizedLiveMigration () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_ENSURE_DECENTRALIZED_LIVE_MIGRATION}" != "true" ]] && return 0

    EnsureDecentralizedLiveMigrationGate "${sourceKubeconfig}"
    EnsureDecentralizedLiveMigrationGate "${destKubeconfig}"
}

# PreflightCclm — verify MTV controller and KubeVirt gates.
function PreflightCclm () {
    typeset fcGate envVal

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    fcGate="$(HubOc get "forkliftcontroller/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.feature_ocp_live_migration}' || true)"
    [[ "${fcGate}" == "true" ]]

    envVal="$(HubOc get "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
        || true)"
    [[ "${envVal}" == "true" ]]

    HasDecentralizedLiveMigrationGate "${sourceKubeconfig}"
    HasDecentralizedLiveMigrationGate "${destKubeconfig}"
}

# GetSyncControllerPodIp — first Running virt-synchronization-controller pod IP.
function GetSyncControllerPodIp () {
    typeset kc="${1:?}"; (($#)) && shift

    oc --kubeconfig="${kc}" get pods -n "${MTV_CNV_NAMESPACE}" -o json \
        | jq -r 'first(
            .items[]
            | select(.metadata.name | startswith("virt-synchronization-controller"))
            | select(.status.phase == "Running")
            | select((.status.podIP // "") != "")
            | .status.podIP
        )'
}

# WaitForSyncControllerReady — CCLM requires sync controller on both spokes.
function WaitForSyncControllerReady () {
    typeset kc="${1:?}"; (($#)) && shift

    oc --kubeconfig="${kc}" wait deployment/virt-synchronization-controller \
        -n "${MTV_CNV_NAMESPACE}" --for=condition=Available --timeout="${MTV_SYNC_CONTROLLER_WAIT}"
}

# MaybeWaitForSyncControllers — wait for sync controller deployments on both spokes.
function MaybeWaitForSyncControllers () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    WaitForSyncControllerReady "${sourceKubeconfig}"
    WaitForSyncControllerReady "${destKubeconfig}"
}

# PreflightSubmarinerNoGlobalnet — Globalnet breaks pod IP CCLM sync routing.
function PreflightSubmarinerNoGlobalnet () {
    typeset kc="${1:?}"; (($#)) && shift

    ! oc --kubeconfig="${kc}" get daemonset submariner-globalnet \
        -n submariner-operator 1>/dev/null
}

# MaybePreflightSubmarinerNoGlobalnet — both spokes must not run Globalnet.
function MaybePreflightSubmarinerNoGlobalnet () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    PreflightSubmarinerNoGlobalnet "${sourceKubeconfig}"
    PreflightSubmarinerNoGlobalnet "${destKubeconfig}"
}

# GetSourceVirtLauncherPod — virt-launcher pod for a given VM on source spoke.
# Filters for Running phase and no deletionTimestamp to avoid Terminating/Pending pods.
function GetSourceVirtLauncherPod () {
    typeset vmName="${1:?}"; (($#)) && shift
    typeset podName

    podName="$(SourceOc get pods -n "${MTV_TEST_VM_NAMESPACE}" -o json \
        | jq -r --arg name "${vmName}" \
            'first(.items[]
             | select(.metadata.labels["kubevirt.io/domain"]==$name)
             | select(.status.phase=="Running")
             | select(.metadata.deletionTimestamp==null)
             | .metadata.name) // ""' \
        || true)"
    [[ -n "${podName}" ]] && printf '%s' "${podName}" && return 0

    podName="$(SourceOc get pods -n "${MTV_TEST_VM_NAMESPACE}" -o json \
        | jq -r --arg name "${vmName}" \
            'first(.items[]
             | select(.metadata.name | startswith("virt-launcher-" + $name))
             | select(.status.phase=="Running")
             | select(.metadata.deletionTimestamp==null)
             | .metadata.name) // ""' \
        || true)"
    [[ -n "${podName}" ]] && printf '%s' "${podName}"
}

# ProbeCclmSyncPortFromPod — TCP probe from an existing pod to sync IP:port.
function ProbeCclmSyncPortFromPod () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset ns="${1:?}"; (($#)) && shift
    typeset podName="${1:?}"; (($#)) && shift
    typeset destIp="${1:?}"; (($#)) && shift
    typeset -i attempt=0 maxAttempts="${MTV_CCLM_SYNC_PROBE_RETRIES}" retrySecs=10

    while (( attempt < maxAttempts )); do
        if oc --kubeconfig="${kc}" exec -n "${ns}" "${podName}" -c compute -- \
               timeout "${MTV_CCLM_SYNC_PROBE_TIMEOUT}" bash -c "echo >/dev/tcp/${destIp}/${MTV_CCLM_SYNC_PORT}"; then
            return 0
        fi
        (( attempt++ )) || true
        if (( attempt < maxAttempts )); then
            : "Sync port probe attempt ${attempt}/${maxAttempts} failed; retrying in ${retrySecs}s"
            sleep "${retrySecs}"
        fi
    done
    return 1
}

# PreflightCclmSyncConnectivity — source must reach dest sync-controller :8443.
# Uses the first VM's virt-launcher as the cluster-level connectivity anchor.
function PreflightCclmSyncConnectivity () {
    typeset destSyncIp srcLauncherPod

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_CCLM_SYNC_PROBE}" != "true" ]] && return 0

    destSyncIp="$(GetSyncControllerPodIp "${destKubeconfig}")"
    [[ -n "${destSyncIp}" ]]

    srcLauncherPod="$(GetSourceVirtLauncherPod "$(VmName 1)")"
    [[ -n "${srcLauncherPod}" ]]

    ProbeCclmSyncPortFromPod \
        "${sourceKubeconfig}" "${MTV_TEST_VM_NAMESPACE}" "${srcLauncherPod}" "${destSyncIp}"
}

# MigrationPipelinePhase — read one pipeline step phase for a VM from Migration status.
function MigrationPipelinePhase () {
    typeset vmName="${1:?}"; (($#)) && shift
    typeset stepName="${1:?}"; (($#)) && shift
    typeset migJson phase

    migJson="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" -o json || true)"
    [[ -n "${migJson}" ]] || return 0

    phase="$(jq -r --arg vm "${vmName}" --arg step "${stepName}" \
        '.status.vms[]? | select(.name == $vm) | .pipeline[]? | select(.name == $step) | .phase' \
        <<<"${migJson}" | head -1)"
    [[ -n "${phase}" && "${phase}" != "null" ]] && printf '%s' "${phase}"
}

# VmimPhase — read VirtualMachineInstanceMigration phase for a specific VM on a spoke.
# Filters by the vmim's vmi name label to handle multi-VM migration plans correctly.
function VmimPhase () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset ns="${1:?}"; (($#)) && shift
    typeset vmName="${1:?}"; (($#)) && shift

    oc --kubeconfig="${kc}" get vmim -n "${ns}" -o json \
        | jq -r --arg vm "${vmName}" \
            'first(.items[] | select(.spec.vmiName == $vm) | .status.phase) // ""' \
        || true
}

# CheckSyncStuck — fail early when any VM's Synchronization does not progress.
# Checks ALL VMs every poll; shared timer starts when the first VM enters Running
# and resets when no VM is in Running sync (i.e., all have advanced past it).
function CheckSyncStuck () {
    typeset -i i anyRunning=0
    typeset syncPhase vmName

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    (( syncStuckMinutes > 0 )) || return 0

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        syncPhase="$(MigrationPipelinePhase "${vmName}" "Synchronization")"
        [[ "${syncPhase}" == "Running" ]] || continue

        (( anyRunning++ )) || true
        (( syncPhaseStartedAt )) || syncPhaseStartedAt="${SECONDS}"

        if (( SECONDS - syncPhaseStartedAt >= syncStuckMinutes * 60 )); then
            typeset srcVmimPhase destVmimPhase
            srcVmimPhase="$(VmimPhase "${sourceKubeconfig}" "${MTV_TEST_VM_NAMESPACE}" "${vmName}")"
            destVmimPhase="$(VmimPhase "${destKubeconfig}" "${targetNs}" "${vmName}")"

            if [[ "${srcVmimPhase}" == "Synchronizing" && "${destVmimPhase}" == "WaitingForSync" ]]; then
                printf 'ERROR: Synchronization stuck >%dm on %s (source=%s, dest=%s)\n' \
                    "${syncStuckMinutes}" "${vmName}" "${srcVmimPhase}" "${destVmimPhase}" >&2
                DumpDiagnostics
                false
            fi
        fi
    done

    (( anyRunning )) || syncPhaseStartedAt=0
    true
}

# RefreshProviderInventory — re-scan spoke KubeVirt inventory before live Plan validation.
function RefreshProviderInventory () {
    typeset providerName="${1:?}"; (($#)) && shift
    typeset ts

    ts="$(date -u +%s)"
    HubOc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# RefreshProvidersForLivePlan — both providers must reflect current KubeVirt feature gates.
function RefreshProvidersForLivePlan () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    RefreshProviderInventory "${MTV_SOURCE_PROVIDER}"
    RefreshProviderInventory "${MTV_DESTINATION_PROVIDER}"
    HubOc wait "provider/${MTV_SOURCE_PROVIDER}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}"
    HubOc wait "provider/${MTV_DESTINATION_PROVIDER}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}"
}

# ApplyPlan — create or update MTV Plan CR including all VMs via jq marshalling.
function ApplyPlan () {
    typeset -i i
    typeset vmsJson="[]"
    typeset planJson

    for (( i = 1; i <= vmCount; i++ )); do
        vmsJson="$(jq -cn \
            --argjson vms "${vmsJson}" \
            --arg name "$(VmName "${i}")" \
            --arg ns "${MTV_TEST_VM_NAMESPACE}" \
            '$vms + [{"name": $name, "namespace": $ns}]')"
    done

    planJson="$(jq -cn \
        --arg planName "${MTV_PLAN_NAME}" \
        --arg ns "${MTV_NAMESPACE}" \
        --arg srcProvider "${MTV_SOURCE_PROVIDER}" \
        --arg dstProvider "${MTV_DESTINATION_PROVIDER}" \
        --arg tgtNs "${targetNs}" \
        --arg netMap "${MTV_NETWORK_MAP_NAME}" \
        --arg storMap "${MTV_STORAGE_MAP_NAME}" \
        --argjson vms "${vmsJson}" \
        --arg planType "${MTV_PLAN_TYPE}" \
        '{
            "apiVersion": "forklift.konveyor.io/v1beta1",
            "kind": "Plan",
            "metadata": {"name": $planName, "namespace": $ns},
            "spec": {
                "provider": {
                    "source": {"name": $srcProvider, "namespace": $ns},
                    "destination": {"name": $dstProvider, "namespace": $ns}
                },
                "targetNamespace": $tgtNs,
                "map": {
                    "network": {"name": $netMap, "namespace": $ns},
                    "storage": {"name": $storMap, "namespace": $ns}
                },
                "vms": $vms,
                "type": $planType
            }
        }')"

    printf '%s\n' "${planJson}" | {
        HubOc create -f - --dry-run=client -o json --save-config |
        jq -c .
    } | HubOc apply -f -
}

# WaitPlanReady — wait for Plan Ready condition.
function WaitPlanReady () {
    HubOc wait "plan/${MTV_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# ApplyMigration — create Migration CR referencing the Plan.
function ApplyMigration () {
    {
        HubOc create -f - --dry-run=client -o yaml --save-config
    } <<EOF | HubOc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: ${MTV_MIGRATION_NAME}
  namespace: ${MTV_NAMESPACE}
spec:
  plan:
    name: ${MTV_PLAN_NAME}
    namespace: ${MTV_NAMESPACE}
EOF
}

# ParseOcWaitDurationSeconds — convert oc wait duration (e.g. 2h, 15m) to seconds.
function ParseOcWaitDurationSeconds () {
    typeset duration="${1:?}"; (($#)) && shift
    if [[ "${duration}" =~ ^([0-9]+)h$ ]]; then
        printf '%d\n' $(( BASH_REMATCH[1] * 3600 ))
    elif [[ "${duration}" =~ ^([0-9]+)m$ ]]; then
        printf '%d\n' $(( BASH_REMATCH[1] * 60 ))
    elif [[ "${duration}" =~ ^([0-9]+)s$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%d\n' 7200
    fi
}

# PrintMigrationPipeline — log migration VM pipeline phases.
function PrintMigrationPipeline () {
    HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
        || true
}

# WaitMigrationSucceeded — poll until Migration Succeeded or Failed.
function WaitMigrationSucceeded () {
    typeset -i deadline
    typeset succeededStatus failedStatus msg

    deadline=$((SECONDS + $(ParseOcWaitDurationSeconds "${MTV_MIGRATION_TIMEOUT}")))

    while (( SECONDS < deadline )); do
        succeededStatus="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
        failedStatus="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"
        msg="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' || true)"

        [[ "${succeededStatus}" == "True" ]] && return 0

        if [[ "${failedStatus}" == "True" ]]; then
            HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' \
                1>&2 || true
            PrintMigrationPipeline 1>&2
            false
        fi

        CheckSyncStuck

        PrintMigrationPipeline
        : "Migration in progress${msg:+: ${msg}} (${SECONDS}/${deadline}s)"
        sleep "${migrationPollInterval}"
    done

    false
}

# VerifyMigration — all destination VMIs must be Running after migration.
function VerifyMigration () {
    typeset -i i
    typeset vmName destPhase

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        destPhase="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
            -o jsonpath='{.status.phase}' || true)"
        [[ "${destPhase}" == "Running" ]] \
            || { : "VMI ${vmName} not Running on destination (phase=${destPhase})"; false; }
    done
}

# VerifyAllVmsSsh — probe SSH port 22 on each migrated VM via a peer virt-launcher.
# Uses cross-VM probing: VM[i] is probed from VM[(i+1)%N]'s virt-launcher, so
# the anchor pod differs from the target VM (avoids hairpin NAT in masquerade mode).
# Skipped for vmCount=1 (no peer launcher; self-probe is meaningless).
# Best-effort: caller wraps with || true so failure is logged but doesn't block.
function VerifyAllVmsSsh () {
    [[ "${vmSshVerify}" == "true" ]] || return 0
    [[ "${MTV_PLAN_TYPE}" == "live" ]] || return 0
    # Self-probe with vmCount=1 would use the same pod as both anchor and target.
    (( vmCount > 1 )) || return 0

    typeset -i i
    typeset -a vmNamesArr=()
    typeset -a launcherPodsArr=()

    # Collect virt-launcher pods for all migrated VMs on destination.
    # VM IPs and pod names are resolved inside set +x to avoid tracing
    # internal cluster endpoint identifiers into CI logs.
    for (( i = 1; i <= vmCount; i++ )); do
        typeset vmn pod
        vmn="$(VmName "${i}")"
        vmNamesArr+=("${vmn}")
        pod="$(DestOc get pods -n "${targetNs}" -o json \
            | jq -r --arg d "${vmn}" \
                'first(.items[]
                 | select(.metadata.labels["kubevirt.io/domain"]==$d)
                 | select(.status.phase=="Running")
                 | .metadata.name) // ""' \
            || true)"
        launcherPodsArr+=("${pod}")
    done

    typeset -i failed=0
    for (( i = 0; i < vmCount; i++ )); do
        typeset vmName
        vmName="${vmNamesArr[${i}]}"

        typeset -i anchorIdx=$(( (i + 1) % vmCount ))

        if [[ -z "${launcherPodsArr[${anchorIdx}]}" ]]; then
            : "No probe anchor available for SSH check on ${vmName}; skipping"
            continue
        fi

        # Resolve VM IP and exec the probe inside a set +x subshell to prevent
        # internal endpoint identifiers from appearing in the xtrace log.
        typeset probeRc=0
        ( set +x
          vmIp="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
              -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
          anchorPod="${launcherPodsArr[${anchorIdx}]}"
          [[ -n "${vmIp}" ]] || exit 2
          DestOc exec -n "${targetNs}" "${anchorPod}" -c compute -- \
              timeout 15 bash -c "echo > /dev/tcp/${vmIp}/22"
        ) || probeRc=$?

        case "${probeRc}" in
            0) : "SSH port 22 reachable on ${vmName}" ;;
            2) : "No IP on VMI ${vmName}; skipping SSH probe" ;;
            *) : "SSH port 22 not reachable on ${vmName} (rc=${probeRc})"
               (( ++failed )) ;;
        esac
    done

    (( failed == 0 ))
}

# JStep — run a function, append PASS/FAIL record to junitFile, propagate exit code.
function JStep () {
    typeset name="${1:?}"; shift
    typeset -i t0=$SECONDS rc=0
    "$@" || rc=$?
    typeset -i elapsed=$(( SECONDS - t0 ))
    if (( rc == 0 )); then
        printf 'PASS\t%s\t%d\t\n' "${name}" "${elapsed}" >> "${junitFile}"
    else
        printf 'FAIL\t%s\t%d\tFailed (rc=%d); see diagnostics in mtv-live-migration-diagnostics/\n' \
            "${name}" "${elapsed}" "${rc}" >> "${junitFile}"
    fi
    return "${rc}"
}

# XmlEscape — replace XML special characters for attribute/text values.
function XmlEscape () {
    typeset s="${1}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

# WriteJunit — emit JUnit XML from accumulated junitFile records.
function WriteJunit () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    [[ -f "${junitFile}" ]] || return 0

    typeset xmlFile="${ARTIFACT_DIR}/junit_cclm_live_migration.xml"
    mkdir -p "${ARTIFACT_DIR}"

    typeset -i total=0 failures=0 totalTime=0
    typeset status name elapsed failMsg

    while IFS=$'\t' read -r status name elapsed failMsg; do
        (( total++ )) || true
        (( totalTime += elapsed )) || true
        [[ "${status}" == "FAIL" ]] && (( failures++ )) || true
    done < "${junitFile}"

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuite name="cclm-live-migration" tests="%d" failures="%d" errors="0" skipped="0" time="%d">\n' \
            "${total}" "${failures}" "${totalTime}"
        while IFS=$'\t' read -r status name elapsed failMsg; do
            typeset escapedName; escapedName="$(XmlEscape "${name}")"
            printf '  <testcase name="%s" classname="cclm-live-migration" time="%d">\n' \
                "${escapedName}" "${elapsed}"
            if [[ "${status}" == "FAIL" ]]; then
                typeset escapedMsg; escapedMsg="$(XmlEscape "${failMsg}")"
                printf '    <failure message="%s">%s</failure>\n' \
                    "${escapedMsg}" "${escapedMsg}"
            fi
            printf '  </testcase>\n'
        done < "${junitFile}"
        printf '</testsuite>\n'
    } > "${xmlFile}"

    : "JUnit XML written -> ${xmlFile} (${total} tests, ${failures} failures, ${totalTime}s total)"
    rm -f "${junitFile}"
}

trap - ERR

typeset -i cclmStepRc=0
(
    trap OnError ERR

    ResolveSpokeKubeconfigs
    targetNs="${targetNs:-${MTV_TEST_VM_NAMESPACE}}"

    [[ "${MTV_PLAN_TYPE}" == "live" || "${MTV_PLAN_TYPE}" == "cold" ]]

    JStep "Preflight: Providers and Maps Ready"          PreflightHub
    JStep "Preflight: DecentralizedLiveMigration Gates"  MaybeEnsureDecentralizedLiveMigration
    JStep "Preflight: Sync Controllers Available"        MaybeWaitForSyncControllers
    JStep "Preflight: MTV CCLM Feature Gate Active"      PreflightCclm
    JStep "Preflight: Submariner No Globalnet"           MaybePreflightSubmarinerNoGlobalnet
    JStep "Preflight: Provider Inventory Refresh"        RefreshProvidersForLivePlan
    JStep "Preflight: Source VMs Running"                PreflightSourceVm
    JStep "Preflight: CCLM Sync Port Reachable"         PreflightCclmSyncConnectivity
    JStep "Preflight: VM Storage Classes Mapped"         PreflightVmStorageMapped
    JStep "Migration: Apply Plan"                        ApplyPlan
    JStep "Migration: Plan Ready"                        WaitPlanReady
    JStep "Migration: Apply Migration"                   ApplyMigration
    JStep "Migration: Succeeded"                         WaitMigrationSucceeded
    JStep "Verification: Destination VMIs Running"       VerifyMigration

    # SSH port probe is best-effort: failure is recorded in JUnit but does not
    # block overall migration success (|| true prevents ERR trap from firing).
    JStep "Verification: VM SSH Port Probe" VerifyAllVmsSsh || true

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            HubOc get "plan/${MTV_PLAN_NAME}" "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" -o wide
            HubOc get "plan/${MTV_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            PrintMigrationPipeline
            typeset -i m
            for (( m = 1; m <= vmCount; m++ )); do
                typeset vn
                vn="$(VmName "${m}")"
                SourceOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
                    -n "${MTV_TEST_VM_NAMESPACE}" -o wide || true
                DestOc get "virtualmachine/${vn}" "virtualmachineinstance/${vn}" \
                    -n "${targetNs}" -o wide || true
            done
        } > "${ARTIFACT_DIR}/mtv-live-migration-status.txt"
    fi
    true
) || cclmStepRc=$?

# Always write JUnit XML — on success and on failure.
WriteJunit

if (( cclmStepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        printf 'WARNING: p2p-mtv-execute-live-migration failed (rc=%d); not failing job (debug mode)\n' "${cclmStepRc}" >&2
    else
        exit "${cclmStepRc}"
    fi
fi

true
