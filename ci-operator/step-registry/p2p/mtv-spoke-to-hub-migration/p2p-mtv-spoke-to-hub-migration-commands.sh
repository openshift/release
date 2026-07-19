#!/bin/bash
#
# Execute the SPOKE→HUB direction of MTV cross-cluster live migration (CCLM).
#
# This is a directional wrapper for p2p-mtv-execute-hub-spoke-migration: it hardcodes
# P2P_MIGRATION_DIRECTION="spoke-to-hub" so that it can appear AFTER a spoke upgrade step
# in a chain, independently of any hub→spoke migration step that ran earlier.
#
# Use this step when you need the sequence:
#   hub→spoke migration → upgrade spoke → [health checks] → spoke→hub migration
#
# The spoke VMs (prefix MTV_HS_SPOKE_VM_PREFIX) that were migrated to the spoke in the
# prior hub→spoke pass are now migrated back to the hub cluster.
#
# All preflight checks run identically to the bidirectional step:
#   providers/maps Ready, DecentralizedLiveMigration featureGate, virt-synchronization-controller
#   Available, Submariner no-Globalnet, inventory refresh, source VMs Running, TCP sync probe.
#
# ACM hub kubeconfig (KUBECONFIG from ci-operator) is used for both MTV API operations and
# hub cluster KubeVirt/VM operations.
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

typeset -i vmCount="${P2P_HS_VM_COUNT}"
typeset -i migrationPollInterval="${MTV_HS_MIGRATION_POLL_INTERVAL_SECONDS}"
typeset -i syncStuckMinutes="${MTV_HS_SYNC_STUCK_MINUTES}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
typeset spokeKubeconfig=""

# Temp file for JUnit records (PASS/FAIL\tname\telapsed\t[msg]).
typeset -r junitFile="${TMPDIR:-/tmp}/hub-spoke-cclm-junit-$$.tsv"

typeset diagDir=""

# HubOc — run oc against the ACM hub (MTV management plane + hub KubeVirt endpoint).
HubOc() {
    oc --kubeconfig="${KUBECONFIG}" "$@"
}

# SpokeOc — run oc against the spoke cluster.
SpokeOc() {
    oc --kubeconfig="${spokeKubeconfig}" "$@"
}

# ResolveSpokeKubeconfig — resolve spoke kubeconfig from explicit env or SHARED_DIR index.
ResolveSpokeKubeconfig() {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -n "${MTV_HS_SPOKE_KUBECONFIG}" ]]; then
        spokeKubeconfig="${MTV_HS_SPOKE_KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${MTV_HS_SPOKE_INDEX}" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${MTV_HS_SPOKE_INDEX}"
    elif [[ "${MTV_HS_SPOKE_INDEX}" == "1" && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
        : "Spoke kubeconfig not found for index ${MTV_HS_SPOKE_INDEX}" >&2
        return 1
    fi
    [[ -r "${spokeKubeconfig}" ]]
}

# KcForCluster — return kubeconfig path for "hub" or "spoke" label.
KcForCluster() {
    typeset cluster="${1:?}"
    case "${cluster}" in
        hub)   printf '%s' "${KUBECONFIG}" ;;
        spoke) printf '%s' "${spokeKubeconfig}" ;;
        *) : "Unknown cluster label: ${cluster}" >&2; return 1 ;;
    esac
}

# ----------------------------- Preflight functions ----------------------------

# WaitProviderReady — gate until MTV Provider is Ready.
WaitProviderReady() {
    typeset providerName="${1:?}"
    HubOc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PLAN_READY_TIMEOUT}"
}

# WaitMapReady — gate until NetworkMap or StorageMap is Ready.
WaitMapReady() {
    typeset kind="${1:?}"
    typeset name="${2:?}"
    HubOc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PLAN_READY_TIMEOUT}"
}

# PreflightHub — both providers and both maps must be Ready before Plan creation.
PreflightHub() {
    typeset srcProvider="${1:?}"
    typeset dstProvider="${2:?}"
    typeset netMapName="${3:?}"
    typeset storMapName="${4:?}"

    WaitProviderReady "${srcProvider}"
    WaitProviderReady "${dstProvider}"
    WaitMapReady networkmap "${netMapName}"
    WaitMapReady storagemap "${storMapName}"
}

# HasDecentralizedLiveMigrationGate — check KubeVirt featureGate presence on a cluster.
HasDecentralizedLiveMigrationGate() {
    typeset kc="${1:?}"

    oc --kubeconfig="${kc}" get kubevirt "${MTV_HS_KUBEVIRT_NAME}" \
        -n "${MTV_HS_CNV_NAMESPACE}" -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        > /dev/null
}

# WaitForDecentralizedLiveMigrationGate — poll KubeVirt until gate appears.
WaitForDecentralizedLiveMigrationGate() {
    typeset kc="${1:?}"
    typeset -i deadline=$((SECONDS + 600))

    while (( SECONDS < deadline )); do
        HasDecentralizedLiveMigrationGate "${kc}" && return 0
        sleep 10
    done
    false
}

# EnsureDecentralizedLiveMigrationGate — enable CCLM gate via HCO; wait for KubeVirt sync.
EnsureDecentralizedLiveMigrationGate() {
    typeset kc="${1:?}"
    typeset clusterLabel="${2:?}"
    typeset hcoGate

    HasDecentralizedLiveMigrationGate "${kc}" && return 0
    : "Enabling DecentralizedLiveMigration featureGate on ${clusterLabel}"

    hcoGate="$(oc --kubeconfig="${kc}" get hyperconverged "${MTV_HS_HCO_NAME}" \
        -n "${MTV_HS_CNV_NAMESPACE}" \
        -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' || true)"
    if [[ "${hcoGate}" != "true" ]]; then
        oc --kubeconfig="${kc}" patch hyperconverged "${MTV_HS_HCO_NAME}" \
            -n "${MTV_HS_CNV_NAMESPACE}" \
            --type merge -p '{"spec":{"featureGates":{"decentralizedLiveMigration":true}}}'
    fi

    WaitForDecentralizedLiveMigrationGate "${kc}" && return 0

    oc --kubeconfig="${kc}" patch kubevirt "${MTV_HS_KUBEVIRT_NAME}" \
        -n "${MTV_HS_CNV_NAMESPACE}" \
        --type merge \
        -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates":["DecentralizedLiveMigration"]}}}}'

    WaitForDecentralizedLiveMigrationGate "${kc}"
}

# MaybeEnsureDecentralizedLiveMigration — enable CCLM gate on both hub and spoke.
MaybeEnsureDecentralizedLiveMigration() {
    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_HS_ENSURE_DECENTRALIZED_LIVE_MIGRATION}" != "true" ]] && return 0

    EnsureDecentralizedLiveMigrationGate "${KUBECONFIG}"      "hub"
    EnsureDecentralizedLiveMigrationGate "${spokeKubeconfig}" "spoke"
}

# WaitForSyncControllerReady — CCLM requires virt-synchronization-controller on both clusters.
WaitForSyncControllerReady() {
    typeset kc="${1:?}"
    typeset clusterLabel="${2:?}"

    : "Waiting for virt-synchronization-controller on ${clusterLabel}"
    oc --kubeconfig="${kc}" wait deployment/virt-synchronization-controller \
        -n "${MTV_HS_CNV_NAMESPACE}" --for=condition=Available \
        --timeout="${MTV_HS_SYNC_CONTROLLER_WAIT}"
}

# MaybeWaitForSyncControllers — wait for sync controllers on both hub and spoke.
MaybeWaitForSyncControllers() {
    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    WaitForSyncControllerReady "${KUBECONFIG}"      "hub"
    WaitForSyncControllerReady "${spokeKubeconfig}" "spoke"
}

# PreflightCclm — verify ForkliftController CCLM gate and KubeVirt featureGates.
PreflightCclm() {
    typeset srcKc="${1:?}"
    typeset dstKc="${2:?}"
    typeset fcGate envVal

    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    fcGate="$(HubOc get "forkliftcontroller/${MTV_HS_FORKLIFT_CONTROLLER_NAME}" \
        -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.feature_ocp_live_migration}' || true)"
    [[ "${fcGate}" == "true" ]]

    envVal="$(HubOc get "deployment/${MTV_HS_FORKLIFT_CONTROLLER_NAME}" \
        -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
        || true)"
    [[ "${envVal}" == "true" ]]

    HasDecentralizedLiveMigrationGate "${srcKc}"
    HasDecentralizedLiveMigrationGate "${dstKc}"
}

# PreflightSubmarinerNoGlobalnet — Globalnet breaks raw pod-IP sync routing.
PreflightSubmarinerNoGlobalnet() {
    typeset kc="${1:?}"
    typeset clusterLabel="${2:?}"

    # Submariner Globalnet daemonset should NOT exist; ! inverts exit code.
    ! oc --kubeconfig="${kc}" get daemonset submariner-globalnet \
        -n submariner-operator 1>/dev/null
}

# MaybePreflightSubmarinerNoGlobalnet — check both hub and spoke.
MaybePreflightSubmarinerNoGlobalnet() {
    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    PreflightSubmarinerNoGlobalnet "${KUBECONFIG}"      "hub"
    PreflightSubmarinerNoGlobalnet "${spokeKubeconfig}" "spoke"
}

# RefreshProviderInventory — re-scan cluster KubeVirt inventory before live Plan validation.
RefreshProviderInventory() {
    typeset providerName="${1:?}"
    typeset ts

    ts="$(date -u +%s)"
    HubOc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# RefreshProvidersForLivePlan — providers must reflect current KubeVirt feature gates.
RefreshProvidersForLivePlan() {
    typeset srcProvider="${1:?}"
    typeset dstProvider="${2:?}"

    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    RefreshProviderInventory "${srcProvider}"
    RefreshProviderInventory "${dstProvider}"
    HubOc wait "provider/${srcProvider}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PROVIDER_INVENTORY_REFRESH_WAIT}"
    HubOc wait "provider/${dstProvider}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PROVIDER_INVENTORY_REFRESH_WAIT}"
}

# PreflightAllSourceVmsRunning — all source VMs must be Running for live migration.
PreflightAllSourceVmsRunning() {
    typeset kc="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset vmNs="${3:?}"
    typeset -i i
    typeset phase

    for ((i = 1; i <= vmCount; i++)); do
        typeset vmName="${vmPrefix}-${i}"
        oc --kubeconfig="${kc}" get "virtualmachine/${vmName}" -n "${vmNs}" 1>/dev/null

        if [[ "${MTV_HS_PLAN_TYPE}" == "live" ]]; then
            phase="$(oc --kubeconfig="${kc}" get "virtualmachineinstance/${vmName}" -n "${vmNs}" \
                -o jsonpath='{.status.phase}' || true)"
            [[ "${phase}" == "Running" ]]
        fi
    done
}

# GetSyncControllerPodIp — first Running virt-synchronization-controller pod IP.
GetSyncControllerPodIp() {
    typeset kc="${1:?}"

    oc --kubeconfig="${kc}" get pods -n "${MTV_HS_CNV_NAMESPACE}" -o json \
        | jq -r 'first(
            .items[]
            | select(.metadata.name | startswith("virt-synchronization-controller"))
            | select(.status.phase == "Running")
            | select((.status.podIP // "") != "")
            | .status.podIP
        )'
}

# GetSourceVirtLauncherPod — virt-launcher pod for the first source VM (representative probe).
GetSourceVirtLauncherPod() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset vmNs="${3:?}"
    typeset podName

    podName="$(oc --kubeconfig="${kc}" get pods -n "${vmNs}" \
        -l "kubevirt.io=virt-launcher,kubevirt.io/domain=${vmName}" \
        -o jsonpath='{.items[0].metadata.name}' || true)"
    [[ -n "${podName}" ]] && printf '%s' "${podName}" && return 0

    oc --kubeconfig="${kc}" get pods -n "${vmNs}" -o json \
        | jq -r --arg name "${vmName}" \
            '[.items[].metadata.name | select(startswith("virt-launcher-" + $name))] | first // ""' \
        || true
}

# ProbeCclmSyncPortFromPod — TCP probe from source virt-launcher to destination sync controller.
ProbeCclmSyncPortFromPod() {
    typeset kc="${1:?}"
    typeset ns="${2:?}"
    typeset podName="${3:?}"
    typeset destIp="${4:?}"
    typeset -i attempt=0 maxAttempts="${MTV_HS_CCLM_SYNC_PROBE_RETRIES}" retrySecs=10

    while (( attempt < maxAttempts )); do
        if oc --kubeconfig="${kc}" exec -n "${ns}" "${podName}" -c compute -- \
               timeout "${MTV_HS_CCLM_SYNC_PROBE_TIMEOUT}" bash -c "echo >/dev/tcp/${destIp}/${MTV_HS_CCLM_SYNC_PORT}"; then
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

# PreflightCclmSyncConnectivity — source must reach destination sync-controller TCP port.
# For hub→spoke: probe from hub virt-launcher pod → spoke sync-controller.
# For spoke→hub: probe from spoke virt-launcher pod → hub sync-controller.
PreflightCclmSyncConnectivity() {
    typeset srcKc="${1:?}"
    typeset dstKc="${2:?}"
    typeset vmPrefix="${3:?}"
    typeset vmNs="${4:?}"
    typeset destSyncIp srcLauncherPod

    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_HS_CCLM_SYNC_PROBE}" != "true" ]] && return 0

    destSyncIp="$(GetSyncControllerPodIp "${dstKc}")"
    [[ -n "${destSyncIp}" ]]

    # Use first VM's virt-launcher as representative connectivity probe.
    srcLauncherPod="$(GetSourceVirtLauncherPod "${srcKc}" "${vmPrefix}-1" "${vmNs}")"
    [[ -n "${srcLauncherPod}" ]]

    ProbeCclmSyncPortFromPod "${srcKc}" "${vmNs}" "${srcLauncherPod}" "${destSyncIp}"
}

# GetVmRootDiskStorageClass — resolve root disk StorageClass from first source VM.
GetVmRootDiskStorageClass() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset vmNs="${3:?}"
    typeset dvName pvcName scName

    dvName="$(oc --kubeconfig="${kc}" get "virtualmachine/${vmName}" -n "${vmNs}" -o json \
        | jq -r 'first(.spec.template.spec.volumes[]?.dataVolume.name // empty) // ""')"
    [[ -z "${dvName}" ]] && dvName="${vmName}-rootdisk"

    pvcName="$(oc --kubeconfig="${kc}" get "datavolume/${dvName}" -n "${vmNs}" \
        -o jsonpath='{.status.claimName}' || true)"
    [[ -z "${pvcName}" ]] && pvcName="${dvName}"

    scName="$(oc --kubeconfig="${kc}" get "persistentvolumeclaim/${pvcName}" -n "${vmNs}" \
        -o jsonpath='{.spec.storageClassName}' || true)"
    [[ -n "${scName}" ]] && printf '%s' "${scName}" && return 0

    oc --kubeconfig="${kc}" get pvc -n "${vmNs}" -o json \
        | jq -r --arg pvc "${pvcName}" '
            (first(.items[] | select(.metadata.name == $pvc) | .spec.storageClassName) //
             first(.items[].spec.storageClassName) //
             "") // ""
        '
}

# PreflightVmStorageMapped — first VM root disk StorageClass must be in StorageMap.
PreflightVmStorageMapped() {
    typeset srcKc="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset vmNs="${3:?}"
    typeset storMapName="${4:?}"
    typeset vmSc scUid mapJson mapped

    vmSc="$(GetVmRootDiskStorageClass "${srcKc}" "${vmPrefix}-1" "${vmNs}")"
    [[ -n "${vmSc}" ]]

    scUid="$(oc --kubeconfig="${srcKc}" get "storageclass/${vmSc}" \
        -o jsonpath='{.metadata.uid}' || true)"
    mapJson="$(HubOc get "storagemap/${storMapName}" -n "${MTV_NAMESPACE}" -o json)"
    mapped="$(jq -r --arg sc "${vmSc}" --arg uid "${scUid}" \
        '[.spec.map[]? | select(.source.name == $sc or (.source.id != null and .source.id == $uid))] | length > 0' \
        <<<"${mapJson}")"
    [[ "${mapped}" == "true" ]]
}

# ----------------------------- Plan / Migration functions ---------------------

# BuildVmsJson — build the Plan spec.vms JSON array from VM prefix and count.
BuildVmsJson() {
    typeset vmPrefix="${1:?}"
    typeset vmNs="${2:?}"
    typeset -i i
    typeset vmsJson='[]'

    for ((i = 1; i <= vmCount; i++)); do
        vmsJson="$(jq -c \
            --arg name "${vmPrefix}-${i}" \
            --arg ns   "${vmNs}" \
            '. += [{"name": $name, "namespace": $ns}]' <<< "${vmsJson}")"
    done
    printf '%s' "${vmsJson}"
}

# ApplyPlan — create or update MTV Plan CR with multiple VMs on the hub.
ApplyPlan() {
    typeset planName="${1:?}"
    typeset srcProvider="${2:?}"
    typeset dstProvider="${3:?}"
    typeset netMapName="${4:?}"
    typeset storMapName="${5:?}"
    typeset targetNs="${6:?}"
    typeset vmsJson="${7:?}"

    jq -cn \
        --arg name     "${planName}" \
        --arg ns       "${MTV_NAMESPACE}" \
        --arg srcProv  "${srcProvider}" \
        --arg dstProv  "${dstProvider}" \
        --arg netMap   "${netMapName}" \
        --arg storMap  "${storMapName}" \
        --arg tgtNs    "${targetNs}" \
        --argjson vms  "${vmsJson}" \
        --arg planType "${MTV_HS_PLAN_TYPE}" \
        '{
            apiVersion: "forklift.konveyor.io/v1beta1",
            kind: "Plan",
            metadata: {name: $name, namespace: $ns},
            spec: {
                provider: {
                    source:      {name: $srcProv, namespace: $ns},
                    destination: {name: $dstProv, namespace: $ns}
                },
                targetNamespace: $tgtNs,
                map: {
                    network: {name: $netMap, namespace: $ns},
                    storage: {name: $storMap, namespace: $ns}
                },
                vms: $vms,
                type: $planType
            }
        }' | HubOc create -f - --dry-run=client -o yaml --save-config | HubOc apply -f -
}

# WaitPlanReady — wait for Plan Ready condition.
WaitPlanReady() {
    typeset planName="${1:?}"
    HubOc wait "plan/${planName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PLAN_READY_TIMEOUT}"
}

# ApplyMigration — create Migration CR referencing the Plan.
ApplyMigration() {
    typeset migName="${1:?}"
    typeset planName="${2:?}"

    {
        HubOc create -f - --dry-run=client -o yaml --save-config
    } <<EOF | HubOc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: ${migName}
  namespace: ${MTV_NAMESPACE}
spec:
  plan:
    name: ${planName}
    namespace: ${MTV_NAMESPACE}
EOF
}

# ParseOcWaitDurationSeconds — convert oc wait duration (2h, 15m) to seconds.
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
    typeset migName="${1:?}"
    HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
        || true
}

# MigrationPipelinePhase — read one pipeline step phase for a VM.
MigrationPipelinePhase() {
    typeset migName="${1:?}"
    typeset vmName="${2:?}"
    typeset stepName="${3:?}"
    typeset migJson phase

    migJson="$(HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" -o json || true)"
    [[ -n "${migJson}" ]] || return 0

    phase="$(jq -r --arg vm "${vmName}" --arg step "${stepName}" \
        '.status.vms[]? | select(.name == $vm) | .pipeline[]? | select(.name == $step) | .phase' \
        <<<"${migJson}" | head -1)"
    [[ -n "${phase}" && "${phase}" != "null" ]] && printf '%s' "${phase}"
}

# CheckSyncStuck — fail early when Synchronization stays stuck beyond threshold.
CheckSyncStuck() {
    typeset migName="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset srcKc="${3:?}"
    typeset srcNs="${4:?}"
    typeset dstKc="${5:?}"
    typeset dstNs="${6:?}"
    typeset -n syncStartedAtRef="${7:?}"

    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0
    (( syncStuckMinutes > 0 )) || return 0

    typeset syncPhase
    syncPhase="$(MigrationPipelinePhase "${migName}" "${vmPrefix}-1" "Synchronization")"
    [[ "${syncPhase}" == "Running" ]] || {
        syncStartedAtRef=0
        return 0
    }

    (( syncStartedAtRef )) || syncStartedAtRef="${SECONDS}"

    if (( SECONDS - syncStartedAtRef < syncStuckMinutes * 60 )); then
        return 0
    fi

    typeset srcVmimPhase destVmimPhase
    srcVmimPhase="$(oc --kubeconfig="${srcKc}" get vmim -n "${srcNs}" \
        -o jsonpath='{.items[0].status.phase}' || true)"
    destVmimPhase="$(oc --kubeconfig="${dstKc}" get vmim -n "${dstNs}" \
        -o jsonpath='{.items[0].status.phase}' || true)"

    if [[ "${srcVmimPhase}" == "Synchronizing" && "${destVmimPhase}" == "WaitingForSync" ]]; then
        : "Sync stuck >${syncStuckMinutes}m for ${migName} (src=${srcVmimPhase}, dst=${destVmimPhase})"
        false
    fi

    true
}

# WaitMigrationSucceeded — poll until Migration Succeeded or Failed.
WaitMigrationSucceeded() {
    typeset migName="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset srcKc="${3:?}"
    typeset srcNs="${4:?}"
    typeset dstKc="${5:?}"
    typeset dstNs="${6:?}"
    typeset -i deadline syncStartedAt=0
    typeset succeededStatus failedStatus msg

    deadline=$((SECONDS + $(ParseOcWaitDurationSeconds "${MTV_HS_MIGRATION_TIMEOUT}")))

    while (( SECONDS < deadline )); do
        succeededStatus="$(HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
        failedStatus="$(HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"
        msg="$(HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' || true)"

        [[ "${succeededStatus}" == "True" ]] && return 0

        if [[ "${failedStatus}" == "True" ]]; then
            HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' \
                1>&2 || true
            PrintMigrationPipeline "${migName}" 1>&2
            false
        fi

        CheckSyncStuck "${migName}" "${vmPrefix}" \
            "${srcKc}" "${srcNs}" "${dstKc}" "${dstNs}" syncStartedAt

        PrintMigrationPipeline "${migName}"
        : "Migration ${migName} in progress${msg:+: ${msg}} (${SECONDS}/${deadline}s)"
        sleep "${migrationPollInterval}"
    done

    false
}

# VerifyAllVmsMigrated — all destination VMIs must be Running after migration.
VerifyAllVmsMigrated() {
    typeset dstKc="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset vmNs="${3:?}"
    typeset -i i
    typeset phase

    for ((i = 1; i <= vmCount; i++)); do
        typeset vmName="${vmPrefix}-${i}"
        phase="$(oc --kubeconfig="${dstKc}" get "virtualmachineinstance/${vmName}" -n "${vmNs}" \
            -o jsonpath='{.status.phase}' || true)"
        [[ "${phase}" == "Running" ]]
    done
}

# ----------------------------- JUnit helpers ----------------------------------

JStep() {
    typeset name="${1:?}"; shift
    typeset -i t0=$SECONDS rc=0
    "$@" || rc=$?
    typeset -i elapsed=$(( SECONDS - t0 ))
    if (( rc == 0 )); then
        printf 'PASS\t%s\t%d\t\n' "${name}" "${elapsed}" >> "${junitFile}"
    else
        printf 'FAIL\t%s\t%d\tFailed (rc=%d); see diagnostics in hub-spoke-migration-diagnostics/\n' \
            "${name}" "${elapsed}" "${rc}" >> "${junitFile}"
    fi
    return "${rc}"
}

XmlEscape() {
    typeset s="${1}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    printf '%s' "${s}"
}

WriteJunit() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    [[ -f "${junitFile}" ]] || return 0

    typeset xmlFile="${ARTIFACT_DIR}/junit_hub_spoke_cclm_migration.xml"
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
        printf '<testsuite name="hub-spoke-cclm-migration" tests="%d" failures="%d" errors="0" skipped="0" time="%d">\n' \
            "${total}" "${failures}" "${totalTime}"
        while IFS=$'\t' read -r status name elapsed failMsg; do
            typeset escapedName; escapedName="$(XmlEscape "${name}")"
            printf '  <testcase name="%s" classname="hub-spoke-cclm-migration" time="%d">\n' \
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

# ----------------------------- Diagnostics ------------------------------------

DumpDirectionDiagnostics() {
    typeset direction="${1:?}"
    typeset planName="${2:?}"
    typeset migName="${3:?}"
    typeset srcKc="${4:?}"
    typeset dstKc="${5:?}"
    typeset srcNs="${6:?}"
    typeset dstNs="${7:?}"
    typeset vmPrefix="${8:?}"

    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset dirDiag="${ARTIFACT_DIR}/hub-spoke-migration-diagnostics/${direction}"
    mkdir -p "${dirDiag}"

    HubOc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${dirDiag}/hub-mtv-resources.txt" 2>&1 || true
    HubOc describe "plan/${planName}" -n "${MTV_NAMESPACE}" \
        > "${dirDiag}/plan-describe.txt" 2>&1 || true
    HubOc describe "migration/${migName}" -n "${MTV_NAMESPACE}" \
        > "${dirDiag}/migration-describe.txt" 2>&1 || true
    HubOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${dirDiag}/hub-mtv-events.txt" 2>&1 || true

    typeset -i i
    for ((i = 1; i <= vmCount; i++)); do
        typeset vmName="${vmPrefix}-${i}"
        {
            oc --kubeconfig="${srcKc}" get \
                "virtualmachine/${vmName}" "virtualmachineinstance/${vmName}" \
                -n "${srcNs}" -o wide
            oc --kubeconfig="${dstKc}" get \
                "virtualmachine/${vmName}" "virtualmachineinstance/${vmName}" \
                -n "${dstNs}" -o wide
        } > "${dirDiag}/vm-${i}-status.txt" 2>&1 || true
    done

    oc --kubeconfig="${srcKc}" get vmim -n "${srcNs}" -o yaml \
        > "${dirDiag}/source-vmim.yaml" 2>&1 || true
    oc --kubeconfig="${dstKc}" get vmim -n "${dstNs}" -o yaml \
        > "${dirDiag}/dest-vmim.yaml" 2>&1 || true
    oc --kubeconfig="${srcKc}" logs -n "${MTV_HS_CNV_NAMESPACE}" \
        -l kubevirt.io=virt-controller --tail=100 \
        > "${dirDiag}/source-virt-controller.log" 2>&1 || true
    oc --kubeconfig="${dstKc}" logs -n "${MTV_HS_CNV_NAMESPACE}" \
        -l kubevirt.io=virt-controller --tail=100 \
        > "${dirDiag}/dest-virt-controller.log" 2>&1 || true
}

DumpDiagnostics() {
    typeset hubToSpokeTargetNs="${1:-${MTV_HS_HUB_VM_NAMESPACE}}"
    typeset spokeToHubTargetNs="${2:-${MTV_HS_SPOKE_VM_NAMESPACE}}"

    DumpDirectionDiagnostics "hub-to-spoke" \
        "${MTV_HS_HUB_TO_SPOKE_PLAN}" "${MTV_HS_HUB_TO_SPOKE_MIGRATION}" \
        "${KUBECONFIG}" "${spokeKubeconfig}" \
        "${MTV_HS_HUB_VM_NAMESPACE}" "${hubToSpokeTargetNs}" \
        "${MTV_HS_HUB_VM_PREFIX}" || true
    DumpDirectionDiagnostics "spoke-to-hub" \
        "${MTV_HS_SPOKE_TO_HUB_PLAN}" "${MTV_HS_SPOKE_TO_HUB_MIGRATION}" \
        "${spokeKubeconfig}" "${KUBECONFIG}" \
        "${MTV_HS_SPOKE_VM_NAMESPACE}" "${spokeToHubTargetNs}" \
        "${MTV_HS_SPOKE_VM_PREFIX}" || true
}

OnError() {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# ----------------------------- Per-direction migration orchestrator ------------

RunOneMigrationDirection() {
    typeset direction="${1:?}"
    typeset srcProvider="${2:?}"
    typeset dstProvider="${3:?}"
    typeset netMapName="${4:?}"
    typeset storMapName="${5:?}"
    typeset planName="${6:?}"
    typeset migName="${7:?}"
    typeset vmPrefix="${8:?}"
    typeset vmNs="${9:?}"
    typeset targetNs="${10:?}"
    typeset srcKc="${11:?}"
    typeset dstKc="${12:?}"
    typeset vmsJson

    : "=== Starting ${direction} migration: ${srcProvider} → ${dstProvider} (${vmCount} VMs) ==="

    JStep "[${direction}] Preflight: Providers and Maps Ready" \
        PreflightHub "${srcProvider}" "${dstProvider}" "${netMapName}" "${storMapName}"
    JStep "[${direction}] Preflight: DecentralizedLiveMigration Gates" \
        MaybeEnsureDecentralizedLiveMigration
    JStep "[${direction}] Preflight: Sync Controllers Available (hub + spoke)" \
        MaybeWaitForSyncControllers
    JStep "[${direction}] Preflight: MTV CCLM Feature Gate Active" \
        PreflightCclm "${srcKc}" "${dstKc}"
    JStep "[${direction}] Preflight: Submariner No Globalnet" \
        MaybePreflightSubmarinerNoGlobalnet
    JStep "[${direction}] Preflight: Provider Inventory Refresh" \
        RefreshProvidersForLivePlan "${srcProvider}" "${dstProvider}"
    JStep "[${direction}] Preflight: All Source VMs Running" \
        PreflightAllSourceVmsRunning "${srcKc}" "${vmPrefix}" "${vmNs}"
    JStep "[${direction}] Preflight: CCLM Sync Port Reachable" \
        PreflightCclmSyncConnectivity "${srcKc}" "${dstKc}" "${vmPrefix}" "${vmNs}"
    JStep "[${direction}] Preflight: VM Storage Class Mapped" \
        PreflightVmStorageMapped "${srcKc}" "${vmPrefix}" "${vmNs}" "${storMapName}"

    vmsJson="$(BuildVmsJson "${vmPrefix}" "${vmNs}" "${vmCount}")"

    JStep "[${direction}] Migration: Apply Plan (${vmCount} VMs)" \
        ApplyPlan "${planName}" "${srcProvider}" "${dstProvider}" \
            "${netMapName}" "${storMapName}" "${targetNs}" "${vmsJson}"
    JStep "[${direction}] Migration: Plan Ready" \
        WaitPlanReady "${planName}"
    JStep "[${direction}] Migration: Apply Migration" \
        ApplyMigration "${migName}" "${planName}"
    JStep "[${direction}] Migration: Succeeded" \
        WaitMigrationSucceeded "${migName}" "${vmPrefix}" \
            "${srcKc}" "${vmNs}" "${dstKc}" "${targetNs}"
    JStep "[${direction}] Verification: All Destination VMIs Running" \
        VerifyAllVmsMigrated "${dstKc}" "${vmPrefix}" "${targetNs}"

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            HubOc get "plan/${planName}" "migration/${migName}" \
                -n "${MTV_NAMESPACE}" -o wide
            HubOc get "plan/${planName}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            HubOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            PrintMigrationPipeline "${migName}"
            typeset -i i
            for ((i = 1; i <= vmCount; i++)); do
                typeset vmName="${vmPrefix}-${i}"
                oc --kubeconfig="${srcKc}" get \
                    "virtualmachine/${vmName}" "virtualmachineinstance/${vmName}" \
                    -n "${vmNs}" -o wide || true
                oc --kubeconfig="${dstKc}" get \
                    "virtualmachine/${vmName}" "virtualmachineinstance/${vmName}" \
                    -n "${targetNs}" -o wide || true
            done
        } > "${ARTIFACT_DIR}/hub-spoke-${direction}-migration-status.txt"
    fi
    true
}

# ----------------------------- Main -------------------------------------------

trap - ERR

typeset hubToSpokeTargetNs="${MTV_HS_HUB_TO_SPOKE_TARGET_NAMESPACE}"
typeset spokeToHubTargetNs="${MTV_HS_SPOKE_TO_HUB_TARGET_NAMESPACE}"

typeset -i cclmStepRc=0
# Direction is hardcoded to spoke-to-hub regardless of any P2P_MIGRATION_DIRECTION env var
# set in the CI job, ensuring this step always runs only spoke→hub regardless of what the
# prior hub→spoke migration step (p2p-mtv-execute-hub-spoke-migration) was configured to do.
typeset cclmDirection="spoke-to-hub"
(
    trap OnError ERR

    [[ "${MTV_HS_PLAN_TYPE}" == "live" || "${MTV_HS_PLAN_TYPE}" == "cold" ]]
    (( vmCount >= 1 ))
    [[ "${cclmDirection}" == "both" || "${cclmDirection}" == "hub-to-spoke" || "${cclmDirection}" == "spoke-to-hub" ]] || {
        : "ERROR: P2P_MIGRATION_DIRECTION must be 'both', 'hub-to-spoke', or 'spoke-to-hub' (got '${cclmDirection}')"
        exit 1
    }

    ResolveSpokeKubeconfig

    hubToSpokeTargetNs="${hubToSpokeTargetNs:-${MTV_HS_HUB_VM_NAMESPACE}}"
    spokeToHubTargetNs="${spokeToHubTargetNs:-${MTV_HS_SPOKE_VM_NAMESPACE}}"

    HubOc get ns "${MTV_NAMESPACE}" 1>/dev/null

    # Hub→Spoke: hub VMs (hub-vm-1..N) migrate from hub to spoke.
    if [[ "${cclmDirection}" == "hub-to-spoke" || "${cclmDirection}" == "both" ]]; then
        RunOneMigrationDirection "hub-to-spoke" \
            "${MTV_HS_HUB_PROVIDER}" "${MTV_HS_SPOKE_PROVIDER}" \
            "${MTV_HS_HUB_TO_SPOKE_NETWORK_MAP}" "${MTV_HS_HUB_TO_SPOKE_STORAGE_MAP}" \
            "${MTV_HS_HUB_TO_SPOKE_PLAN}" "${MTV_HS_HUB_TO_SPOKE_MIGRATION}" \
            "${MTV_HS_HUB_VM_PREFIX}" "${MTV_HS_HUB_VM_NAMESPACE}" "${hubToSpokeTargetNs}" \
            "${KUBECONFIG}" "${spokeKubeconfig}"
    fi

    # Spoke→Hub: spoke VMs (spoke-vm-1..N) migrate from spoke back to hub.
    if [[ "${cclmDirection}" == "spoke-to-hub" || "${cclmDirection}" == "both" ]]; then
        RunOneMigrationDirection "spoke-to-hub" \
            "${MTV_HS_SPOKE_PROVIDER}" "${MTV_HS_HUB_PROVIDER}" \
            "${MTV_HS_SPOKE_TO_HUB_NETWORK_MAP}" "${MTV_HS_SPOKE_TO_HUB_STORAGE_MAP}" \
            "${MTV_HS_SPOKE_TO_HUB_PLAN}" "${MTV_HS_SPOKE_TO_HUB_MIGRATION}" \
            "${MTV_HS_SPOKE_VM_PREFIX}" "${MTV_HS_SPOKE_VM_NAMESPACE}" "${spokeToHubTargetNs}" \
            "${spokeKubeconfig}" "${KUBECONFIG}"
    fi

    true
) || cclmStepRc=$?

WriteJunit

if (( cclmStepRc != 0 )); then
    DumpDiagnostics "${hubToSpokeTargetNs:-${MTV_HS_HUB_VM_NAMESPACE}}" \
                    "${spokeToHubTargetNs:-${MTV_HS_SPOKE_VM_NAMESPACE}}"
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-mtv-execute-hub-spoke-migration failed (rc=${cclmStepRc}); not failing job (debug mode)"
    else
        exit "${cclmStepRc}"
    fi
fi

true
