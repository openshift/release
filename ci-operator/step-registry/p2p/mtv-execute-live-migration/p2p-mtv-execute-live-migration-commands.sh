#!/bin/bash
#
# Execute MTV cross-cluster live migration (CCLM) from source spoke to destination spoke on the hub.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i migrationPollInterval="${MTV_MIGRATION_POLL_INTERVAL_SECONDS}"
typeset -i sourceSpokeIndex="${MTV_SOURCE_SPOKE_INDEX}"
typeset -i destSpokeIndex="${MTV_DEST_SPOKE_INDEX}"
typeset -i syncStuckMinutes="${MTV_SYNC_STUCK_MINUTES}"
typeset -i syncPhaseStartedAt=0
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"

# Temp file accumulating tab-separated JUnit records (PASS/FAIL\tname\telapsed\t[msg]).
# Written in the subshell; read by WriteJunit after it exits.
typeset -r junitFile="${TMPDIR:-/tmp}/cclm-junit-$$.tsv"

typeset sourceKubeconfig="${MTV_SOURCE_SPOKE_KUBECONFIG}"
typeset destKubeconfig="${MTV_DEST_SPOKE_KUBECONFIG}"
typeset targetNs="${MTV_TEST_VM_TARGET_NAMESPACE}"
typeset diagDir=""

# HubOc — run oc against the ACM hub.
HubOc() {
    oc --kubeconfig="${KUBECONFIG}" "$@"
}

# SourceOc — run oc against the source spoke.
SourceOc() {
    oc --kubeconfig="${sourceKubeconfig}" "$@"
}

# DestOc — run oc against the destination spoke.
DestOc() {
    oc --kubeconfig="${destKubeconfig}" "$@"
}

# ResolveSpokeKubeconfigs — source and destination spoke admin kubeconfigs.
ResolveSpokeKubeconfigs() {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -z "${sourceKubeconfig}" ]]; then
        if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}" ]]; then
            sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}"
        elif (( sourceSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
            sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
        else
            : "Source spoke kubeconfig not found for index ${sourceSpokeIndex}"
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
DumpDiagnostics() {
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
    SourceOc get "virtualmachine/${MTV_TEST_VM_NAME}" "virtualmachineinstance/${MTV_TEST_VM_NAME}" \
        -n "${MTV_TEST_VM_NAMESPACE}" -o wide > "${diagDir}/source-vm.txt" 2>&1 || true
    DestOc get "virtualmachine/${MTV_TEST_VM_NAME}" "virtualmachineinstance/${MTV_TEST_VM_NAME}" \
        -n "${targetNs}" -o wide > "${diagDir}/dest-vm.txt" 2>&1 || true
    DestOc get datavolume,pvc,pods -n "${targetNs}" \
        > "${diagDir}/dest-storage.txt" 2>&1 || true
    SourceOc get vmim -n "${MTV_TEST_VM_NAMESPACE}" -o yaml \
        > "${diagDir}/source-vmim.yaml" 2>&1 || true
    DestOc get vmim -n "${targetNs}" -o yaml \
        > "${diagDir}/dest-vmim.yaml" 2>&1 || true
    SourceOc get "virtualmachineinstance/${MTV_TEST_VM_NAME}" -n "${MTV_TEST_VM_NAMESPACE}" -o yaml \
        > "${diagDir}/source-vmi.yaml" 2>&1 || true
    DestOc get "virtualmachineinstance/${MTV_TEST_VM_NAME}" -n "${targetNs}" -o yaml \
        > "${diagDir}/dest-vmi.yaml" 2>&1 || true
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
OnError() {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# WaitProviderReady — gate until MTV Provider is Ready.
WaitProviderReady() {
    typeset providerName="${1:?}"
    HubOc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# WaitMapReady — gate until NetworkMap or StorageMap is Ready.
WaitMapReady() {
    typeset kind="${1:?}"
    typeset name="${2:?}"
    HubOc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# PreflightSourceVm — source VM must exist and VMI Running for live migration.
PreflightSourceVm() {
    typeset phase

    SourceOc get "virtualmachine/${MTV_TEST_VM_NAME}" -n "${MTV_TEST_VM_NAMESPACE}" 1>/dev/null

    phase="$(SourceOc get "virtualmachineinstance/${MTV_TEST_VM_NAME}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o jsonpath='{.status.phase}' || true)"

    if [[ "${MTV_PLAN_TYPE}" == "live" ]]; then
        [[ "${phase}" == "Running" ]]
    fi
}

# GetVmRootDiskStorageClass — resolve root disk StorageClass from source VM.
GetVmRootDiskStorageClass() {
    typeset dvName pvcName scName

    dvName="$(SourceOc get "virtualmachine/${MTV_TEST_VM_NAME}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o json |
        jq -r 'first(.spec.template.spec.volumes[]?.dataVolume.name // empty) // ""')"
    [[ -z "${dvName}" ]] && dvName="${MTV_TEST_VM_NAME}-rootdisk"

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

# PreflightVmStorageMapped — VM root disk StorageClass must appear in StorageMap.
PreflightVmStorageMapped() {
    typeset vmSc scUid mapJson mapped

    vmSc="$(GetVmRootDiskStorageClass)"
    [[ -n "${vmSc}" ]]

    scUid="$(SourceOc get "storageclass/${vmSc}" -o jsonpath='{.metadata.uid}' || true)"
    mapJson="$(HubOc get "storagemap/${MTV_STORAGE_MAP_NAME}" -n "${MTV_NAMESPACE}" -o json)"
    mapped="$(jq -r --arg sc "${vmSc}" --arg uid "${scUid}" \
        '[.spec.map[]? | select(.source.name == $sc or (.source.id != null and .source.id == $uid))] | length > 0' \
        <<<"${mapJson}")"
    [[ "${mapped}" == "true" ]]
}

# PreflightHub — providers and maps must be Ready before Plan creation.
PreflightHub() {
    WaitProviderReady "${MTV_SOURCE_PROVIDER}"
    WaitProviderReady "${MTV_DESTINATION_PROVIDER}"
    WaitMapReady networkmap "${MTV_NETWORK_MAP_NAME}"
    WaitMapReady storagemap "${MTV_STORAGE_MAP_NAME}"
}

# HasDecentralizedLiveMigrationGate — KubeVirt must list DecentralizedLiveMigration (MTV CCLM check).
HasDecentralizedLiveMigrationGate() {
    typeset kc="${1:?}"

    # jq -e exits 0 when gate present, 1 when absent or oc fails.
    oc --kubeconfig="${kc}" get kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        > /dev/null
}

# EnsureDecentralizedLiveMigrationGate — enable CCLM via HCO featureGates; wait for KubeVirt sync.
EnsureDecentralizedLiveMigrationGate() {
    typeset kc="${1:?}"
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

# WaitForDecentralizedLiveMigrationGate — poll KubeVirt until DecentralizedLiveMigration appears.
WaitForDecentralizedLiveMigrationGate() {
    typeset kc="${1:?}"
    typeset -i deadline=$((SECONDS + 600))

    while (( SECONDS < deadline )); do
        HasDecentralizedLiveMigrationGate "${kc}" && return 0
        sleep 10
    done
    false
}

# MaybeEnsureDecentralizedLiveMigration — enable CCLM gate on both spokes when configured.
MaybeEnsureDecentralizedLiveMigration() {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_ENSURE_DECENTRALIZED_LIVE_MIGRATION}" != "true" ]] && return 0

    EnsureDecentralizedLiveMigrationGate "${sourceKubeconfig}"
    EnsureDecentralizedLiveMigrationGate "${destKubeconfig}"
}

# PreflightCclm — verify MTV controller and KubeVirt gates required for type=live plans.
PreflightCclm() {
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
GetSyncControllerPodIp() {
    typeset kc="${1:?}"

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
WaitForSyncControllerReady() {
    typeset kc="${1:?}"

    oc --kubeconfig="${kc}" wait deployment/virt-synchronization-controller \
        -n "${MTV_CNV_NAMESPACE}" --for=condition=Available --timeout="${MTV_SYNC_CONTROLLER_WAIT}"
}

# MaybeWaitForSyncControllers — wait for sync controller deployments on both spokes.
MaybeWaitForSyncControllers() {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    WaitForSyncControllerReady "${sourceKubeconfig}"
    WaitForSyncControllerReady "${destKubeconfig}"
}

# PreflightSubmarinerNoGlobalnet — Globalnet breaks raw pod IP CCLM sync routing.
PreflightSubmarinerNoGlobalnet() {
    typeset kc="${1:?}"

    # Expected to fail when Globalnet is not deployed; ! inverts the exit code.
    ! oc --kubeconfig="${kc}" get daemonset submariner-globalnet \
        -n submariner-operator 1>/dev/null
}

# MaybePreflightSubmarinerNoGlobalnet — both spokes must not run Globalnet.
MaybePreflightSubmarinerNoGlobalnet() {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    PreflightSubmarinerNoGlobalnet "${sourceKubeconfig}"
    PreflightSubmarinerNoGlobalnet "${destKubeconfig}"
}

# GetSourceVirtLauncherPod — virt-launcher pod name for the source VM.
GetSourceVirtLauncherPod() {
    typeset podName

    podName="$(SourceOc get pods -n "${MTV_TEST_VM_NAMESPACE}" \
        -l "kubevirt.io=virt-launcher,kubevirt.io/domain=${MTV_TEST_VM_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' || true)"
    [[ -n "${podName}" ]] && printf '%s' "${podName}" && return 0

    podName="$(SourceOc get pods -n "${MTV_TEST_VM_NAMESPACE}" -o json \
        | jq -r --arg name "${MTV_TEST_VM_NAME}" \
            '[.items[].metadata.name | select(startswith("virt-launcher-" + $name))] | first // ""' \
        || true)"
    [[ -n "${podName}" ]] && printf '%s' "${podName}"
}

# ProbeCclmSyncPortFromPod — TCP probe from an existing pod to sync IP:port.
# Retries up to MTV_CCLM_SYNC_PROBE_RETRIES times (10s apart) to tolerate the
# window between virt-synchronization-controller Deployment Available and its
# TCP listener being bound (connection-refused causes an instant rc=1 without
# retries, even though connectivity works by migration time).
ProbeCclmSyncPortFromPod() {
    typeset kc="${1:?}"
    typeset ns="${2:?}"
    typeset podName="${3:?}"
    typeset destIp="${4:?}"
    typeset -i attempt=0 maxAttempts="${MTV_CCLM_SYNC_PROBE_RETRIES}" retrySecs=10

    while (( attempt < maxAttempts )); do
        if oc --kubeconfig="${kc}" exec -n "${ns}" "${podName}" -c compute -- \
               timeout "${MTV_CCLM_SYNC_PROBE_TIMEOUT}" bash -c "echo >/dev/tcp/${destIp}/${MTV_CCLM_SYNC_PORT}"; then
            return 0
        fi
        (( attempt++ ))
        if (( attempt < maxAttempts )); then
            : "Sync port probe attempt ${attempt}/${maxAttempts} failed; retrying in ${retrySecs}s"
            sleep "${retrySecs}"
        fi
    done
    return 1
}

# PreflightCclmSyncConnectivity — source must reach dest sync-controller :8443.
PreflightCclmSyncConnectivity() {
    typeset destSyncIp srcLauncherPod

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_CCLM_SYNC_PROBE}" != "true" ]] && return 0

    destSyncIp="$(GetSyncControllerPodIp "${destKubeconfig}")"
    [[ -n "${destSyncIp}" ]]

    srcLauncherPod="$(GetSourceVirtLauncherPod)"
    [[ -n "${srcLauncherPod}" ]]

    ProbeCclmSyncPortFromPod \
        "${sourceKubeconfig}" "${MTV_TEST_VM_NAMESPACE}" "${srcLauncherPod}" "${destSyncIp}"
}

# MigrationPipelinePhase — read one pipeline step phase from Migration status.
MigrationPipelinePhase() {
    typeset stepName="${1:?}"
    typeset migJson phase

    migJson="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" -o json || true)"
    [[ -n "${migJson}" ]] || return 0

    phase="$(jq -r --arg vm "${MTV_TEST_VM_NAME}" --arg step "${stepName}" \
        '.status.vms[]? | select(.name == $vm) | .pipeline[]? | select(.name == $step) | .phase' \
        <<<"${migJson}" | head -1)"
    [[ -n "${phase}" && "${phase}" != "null" ]] && printf '%s' "${phase}"
}

# VmimPhase — read VirtualMachineInstanceMigration phase on a spoke.
VmimPhase() {
    typeset kc="${1:?}"
    typeset ns="${2:?}"

    oc --kubeconfig="${kc}" get vmim -n "${ns}" \
        -o jsonpath='{.items[0].status.phase}' || true
}

# CheckSyncStuck — fail early when Synchronization does not progress.
CheckSyncStuck() {
    typeset syncPhase srcVmimPhase destVmimPhase

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    (( syncStuckMinutes > 0 )) || return 0

    syncPhase="$(MigrationPipelinePhase "Synchronization")"
    [[ "${syncPhase}" == "Running" ]] || {
        syncPhaseStartedAt=0
        return 0
    }

    (( syncPhaseStartedAt )) || syncPhaseStartedAt="${SECONDS}"

    if (( SECONDS - syncPhaseStartedAt < syncStuckMinutes * 60 )); then
        return 0
    fi

    srcVmimPhase="$(VmimPhase "${sourceKubeconfig}" "${MTV_TEST_VM_NAMESPACE}")"
    destVmimPhase="$(VmimPhase "${destKubeconfig}" "${targetNs}")"

    if [[ "${srcVmimPhase}" == "Synchronizing" && "${destVmimPhase}" == "WaitingForSync" ]]; then
        : "Synchronization stuck >${syncStuckMinutes}m (source=${srcVmimPhase}, dest=${destVmimPhase})"
        DumpDiagnostics
        false
    fi

    true
}

# RefreshProviderInventory — re-scan spoke KubeVirt inventory before live Plan validation.
RefreshProviderInventory() {
    typeset providerName="${1:?}"
    typeset ts

    ts="$(date -u +%s)"
    HubOc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# RefreshProvidersForLivePlan — both providers must reflect current KubeVirt feature gates.
RefreshProvidersForLivePlan() {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    RefreshProviderInventory "${MTV_SOURCE_PROVIDER}"
    RefreshProviderInventory "${MTV_DESTINATION_PROVIDER}"
    HubOc wait "provider/${MTV_SOURCE_PROVIDER}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}"
    HubOc wait "provider/${MTV_DESTINATION_PROVIDER}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}"
}

# ApplyPlan — create or update MTV Plan CR on the hub.
ApplyPlan() {
    {
        HubOc create -f - --dry-run=client -o yaml --save-config
    } <<EOF | HubOc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: ${MTV_PLAN_NAME}
  namespace: ${MTV_NAMESPACE}
spec:
  provider:
    source:
      name: ${MTV_SOURCE_PROVIDER}
      namespace: ${MTV_NAMESPACE}
    destination:
      name: ${MTV_DESTINATION_PROVIDER}
      namespace: ${MTV_NAMESPACE}
  targetNamespace: ${targetNs}
  map:
    network:
      name: ${MTV_NETWORK_MAP_NAME}
      namespace: ${MTV_NAMESPACE}
    storage:
      name: ${MTV_STORAGE_MAP_NAME}
      namespace: ${MTV_NAMESPACE}
  vms:
  - name: ${MTV_TEST_VM_NAME}
    namespace: ${MTV_TEST_VM_NAMESPACE}
  type: ${MTV_PLAN_TYPE}
EOF
}

# WaitPlanReady — wait for Plan Ready condition.
WaitPlanReady() {
    HubOc wait "plan/${MTV_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# ApplyMigration — create Migration CR referencing the Plan.
ApplyMigration() {
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
ParseOcWaitDurationSeconds() {
    typeset duration="${1:?}"
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
PrintMigrationPipeline() {
    HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
        || true
}

# WaitMigrationSucceeded — poll until Migration Succeeded or Failed.
WaitMigrationSucceeded() {
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

# VerifyMigration — destination VMI must be Running after migration.
VerifyMigration() {
    typeset destPhase

    destPhase="$(DestOc get "virtualmachineinstance/${MTV_TEST_VM_NAME}" -n "${targetNs}" \
        -o jsonpath='{.status.phase}' || true)"
    [[ "${destPhase}" == "Running" ]]
}

# JStep — run a function, append PASS/FAIL record to junitFile, propagate exit code.
# Usage: JStep "Human readable name" FunctionName [args...]
# The ERR trap in the caller subshell fires when this returns non-zero, so each
# failed step still gets recorded before the trap escalates.
JStep() {
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
# Covers the five predefined XML entities; matches the reference script (p2p-cnv-pre-upgrade).
XmlEscape() {
    typeset s="${1}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

# WriteJunit — emit JUnit XML from accumulated junitFile records.
# Prow/Firewatch pick up junit_*.xml files from ARTIFACT_DIR automatically.
WriteJunit() {
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

    : "JUnit XML written → ${xmlFile} (${total} tests, ${failures} failures, ${totalTime}s total)"
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
    JStep "Preflight: Source VM Running"                 PreflightSourceVm
    JStep "Preflight: CCLM Sync Port Reachable"         PreflightCclmSyncConnectivity
    JStep "Preflight: VM Storage Class Mapped"           PreflightVmStorageMapped
    JStep "Migration: Apply Plan"                        ApplyPlan
    JStep "Migration: Plan Ready"                        WaitPlanReady
    JStep "Migration: Apply Migration"                   ApplyMigration
    JStep "Migration: Succeeded"                         WaitMigrationSucceeded
    JStep "Verification: Destination VMI Running"        VerifyMigration

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            HubOc get "plan/${MTV_PLAN_NAME}" "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" -o wide
            HubOc get "plan/${MTV_PLAN_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            PrintMigrationPipeline
            SourceOc get "virtualmachine/${MTV_TEST_VM_NAME}" "virtualmachineinstance/${MTV_TEST_VM_NAME}" \
                -n "${MTV_TEST_VM_NAMESPACE}" -o wide
            DestOc get "virtualmachine/${MTV_TEST_VM_NAME}" "virtualmachineinstance/${MTV_TEST_VM_NAME}" \
                -n "${targetNs}" -o wide
        } > "${ARTIFACT_DIR}/mtv-live-migration-status.txt"
    fi
    true
) || cclmStepRc=$?

# Always write JUnit XML — both on success and on failure, so Prow/Firewatch
# always has a report regardless of which step caused the subshell to exit.
WriteJunit

if (( cclmStepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-mtv-execute-live-migration failed (rc=${cclmStepRc}); not failing job (debug mode)"
    else
        exit "${cclmStepRc}"
    fi
fi

true
