#!/bin/bash
#
# Execute bi-directional MTV cross-cluster live migration (CCLM) between the ACM hub and a spoke.
#
# The hub is simultaneously the MTV management plane (where Plans and Migrations are created)
# and a KubeVirt cluster that serves as a migration endpoint. The hub "host" provider
# (auto-created by MTV) represents the hub cluster itself.
#
# Two sequential directions:
#   Hub→Spoke: P2P_HS_VM_COUNT VMs (prefix MTV_HS_HUB_VM_PREFIX) from hub cluster → spoke.
#   Spoke→Hub: P2P_HS_VM_COUNT VMs (prefix MTV_HS_SPOKE_VM_PREFIX) from spoke → hub cluster.
#
# Each direction runs full CCLM preflights: providers and maps Ready, DecentralizedLiveMigration
# featureGate on both hub and spoke (patched via HCO when missing), virt-synchronization-controller
# Available on both, Submariner no-Globalnet check, inventory refresh, all source VMs Running,
# TCP probe to destination sync controller, storage class mapped.
#
# ACM hub kubeconfig (KUBECONFIG from ci-operator) is used for both MTV API operations and
# hub cluster KubeVirt/VM operations.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    [[ "${_wasTracing}" == "true" ]] && set -x
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i vmCount="${P2P_HS_VM_COUNT}"
typeset -i migrationPollInterval="${MTV_HS_MIGRATION_POLL_INTERVAL_SECONDS}"
typeset -i syncStuckMinutes="${MTV_HS_SYNC_STUCK_MINUTES}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
# spokeKubeconfig — the source (spoke-1) cluster kubeconfig for hub↔spoke topologies.
# For spoke-spoke topologies this is the first spoke (source cluster).
typeset spokeKubeconfig=""
# destKubeconfig — the destination cluster kubeconfig for spoke-spoke topologies.
# For hub↔spoke topologies this is always KUBECONFIG (the hub); resolved by ResolveSpokeKubeconfig.
typeset destKubeconfig=""

# Temp file for JUnit records (PASS/FAIL\tname\telapsed\t[msg]).
typeset -r junitFile="${TMPDIR:-/tmp}/hub-spoke-cclm-junit-$$.tsv"

typeset diagDir=""

# MgmtOc — run oc against the ACM hub, which is always the MTV management plane.
# The hub hosts Plans, Migrations, Providers, and Maps regardless of which clusters are
# the actual migration endpoints (hub↔spoke or spoke↔spoke).
MgmtOc() {
    oc --kubeconfig="${KUBECONFIG}" "$@"
}
# HubOc — backward-compatible alias for MgmtOc.
HubOc() { MgmtOc "$@"; }

# SpokeOc — run oc against spoke-1 (the source spoke for hub↔spoke or spoke-spoke topologies).
SpokeOc() {
    oc --kubeconfig="${spokeKubeconfig}" "$@"
}

# DestOc — run oc against the destination cluster.
# For hub↔spoke: hub (KUBECONFIG) for spoke→hub, spoke (spokeKubeconfig) for hub→spoke.
# For spoke-spoke: spoke-2 (destKubeconfig).
# Note: for per-direction operations use the explicit srcKc/dstKc parameters instead.
DestOc() {
    oc --kubeconfig="${destKubeconfig}" "$@"
}

# ResolveSpokeKubeconfig — resolve the source spoke kubeconfig from explicit env or SHARED_DIR index.
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

# ResolveDestKubeconfig — resolve the destination cluster kubeconfig for spoke-spoke topologies.
# For hub↔spoke topologies the destination is the hub (KUBECONFIG), which is always available.
# For spoke-spoke, P2P_DEST_KUBECONFIG or P2P_DEST_SPOKE_INDEX must be set.
ResolveDestKubeconfig() {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -n "${P2P_DEST_KUBECONFIG}" ]]; then
        destKubeconfig="${P2P_DEST_KUBECONFIG}"
    elif [[ -n "${P2P_DEST_SPOKE_INDEX}" ]]; then
        if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_DEST_SPOKE_INDEX}" ]]; then
            destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_DEST_SPOKE_INDEX}"
        else
            : "Destination spoke kubeconfig not found for index ${P2P_DEST_SPOKE_INDEX}" >&2
            return 1
        fi
    else
        : "ERROR: spoke-spoke direction requires P2P_DEST_KUBECONFIG or P2P_DEST_SPOKE_INDEX" >&2
        return 1
    fi
    [[ -r "${destKubeconfig}" ]]
}

# KcForCluster — return kubeconfig path for a cluster role label.
KcForCluster() {
    typeset cluster="${1:?}"
    case "${cluster}" in
        hub|mgmt) printf '%s' "${KUBECONFIG}" ;;
        spoke)    printf '%s' "${spokeKubeconfig}" ;;
        dest)     printf '%s' "${destKubeconfig}" ;;
        *) : "Unknown cluster label: ${cluster}" >&2; return 1 ;;
    esac
}

# ----------------------------- Preflight functions ----------------------------

# WaitProviderReady — gate until MTV Provider is Ready.
WaitProviderReady() {
    typeset providerName="${1:?}"
    MgmtOc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PLAN_READY_TIMEOUT}"
}

# WaitMapReady — gate until NetworkMap or StorageMap is Ready.
WaitMapReady() {
    typeset kind="${1:?}"
    typeset name="${2:?}"
    MgmtOc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
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

    # Do NOT fall back to patching KubeVirt directly: a merge patch would
    # replace the entire featureGates array with only DecentralizedLiveMigration,
    # potentially disabling other HCO-managed gates and corrupting cluster state.
    printf 'ERROR: HCO did not propagate DecentralizedLiveMigration featureGate on %s\n' \
        "${clusterLabel}" >&2
    return 1
}

# MaybeEnsureDecentralizedLiveMigration — enable CCLM gate on both source and destination clusters.
# Takes srcKc and dstKc so the function is topology-agnostic (hub↔spoke or spoke↔spoke).
MaybeEnsureDecentralizedLiveMigration() {
    typeset srcKc="${1:?}"
    typeset dstKc="${2:?}"
    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_HS_ENSURE_DECENTRALIZED_LIVE_MIGRATION}" != "true" ]] && return 0

    EnsureDecentralizedLiveMigrationGate "${srcKc}" "src"
    EnsureDecentralizedLiveMigrationGate "${dstKc}" "dst"
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

# MaybeWaitForSyncControllers — wait for sync controllers on both source and destination clusters.
# Takes srcKc and dstKc so the function is topology-agnostic (hub↔spoke or spoke↔spoke).
MaybeWaitForSyncControllers() {
    typeset srcKc="${1:?}"
    typeset dstKc="${2:?}"
    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    WaitForSyncControllerReady "${srcKc}" "src"
    WaitForSyncControllerReady "${dstKc}" "dst"
}

# PreflightCclm — verify ForkliftController CCLM gate and KubeVirt featureGates.
PreflightCclm() {
    typeset srcKc="${1:?}"
    typeset dstKc="${2:?}"
    typeset fcGate envVal

    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    fcGate="$(MgmtOc get "forkliftcontroller/${MTV_HS_FORKLIFT_CONTROLLER_NAME}" \
        -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.feature_ocp_live_migration}' || true)"
    [[ "${fcGate}" == "true" ]]

    envVal="$(MgmtOc get "deployment/${MTV_HS_FORKLIFT_CONTROLLER_NAME}" \
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

# MaybePreflightSubmarinerNoGlobalnet — check both source and destination clusters.
# Takes srcKc and dstKc so the function is topology-agnostic (hub↔spoke or spoke↔spoke).
MaybePreflightSubmarinerNoGlobalnet() {
    typeset srcKc="${1:?}"
    typeset dstKc="${2:?}"
    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    PreflightSubmarinerNoGlobalnet "${srcKc}" "src"
    PreflightSubmarinerNoGlobalnet "${dstKc}" "dst"
}

# RefreshProviderInventory — re-scan cluster KubeVirt inventory before live Plan validation.
RefreshProviderInventory() {
    typeset providerName="${1:?}"
    typeset ts

    ts="$(date -u +%s)"
    MgmtOc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# RefreshProvidersForLivePlan — providers must reflect current KubeVirt feature gates.
RefreshProvidersForLivePlan() {
    typeset srcProvider="${1:?}"
    typeset dstProvider="${2:?}"

    [[ "${MTV_HS_PLAN_TYPE}" != "live" ]] && return 0

    RefreshProviderInventory "${srcProvider}"
    RefreshProviderInventory "${dstProvider}"
    MgmtOc wait "provider/${srcProvider}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PROVIDER_INVENTORY_REFRESH_WAIT}"
    MgmtOc wait "provider/${dstProvider}" -n "${MTV_NAMESPACE}" \
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

    # No fallback to a namespace-wide storage class: returning an unrelated SC
    # would silently pass the StorageMap preflight for a different VM's disk.
    printf 'Unable to resolve root-disk StorageClass for %s in namespace %s\n' \
        "${vmName}" "${vmNs}" >&2
    return 1
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
    mapJson="$(MgmtOc get "storagemap/${storMapName}" -n "${MTV_NAMESPACE}" -o json)"
    mapped="$(jq -r --arg sc "${vmSc}" --arg uid "${scUid}" \
        '[.spec.map[]? | select(.source.name == $sc or (.source.id != null and .source.id == $uid))] | length > 0' \
        <<<"${mapJson}")"
    [[ "${mapped}" == "true" ]]
}

# ----------------------------- Plan / Migration functions ---------------------

# CleanupDestinationStaleResources — remove VM/DV/PVC left on the destination
# cluster after a previous migration leg, preventing MTV PrepareTarget from
# failing with "Target VM already exists" / "MAC address conflicts" on re-runs.
# For the spoke→hub direction, stale spoke-vm-N objects from a prior run land
# in the hub destination namespace and must be cleared before Plan creation.
# Skips per-VM cleanup when the destination VMI is already Running (idempotent).
CleanupDestinationStaleResources() {
    typeset dstKc="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset vmNs="${3:?}"
    typeset -i count="${4:?}"
    typeset -i i

    for ((i = 1; i <= count; i++)); do
        typeset vmName="${vmPrefix}-${i}"
        typeset dvName="${vmName}-rootdisk"

        typeset vmiPhase
        vmiPhase="$(oc --kubeconfig="${dstKc}" get "virtualmachineinstance/${vmName}" \
            -n "${vmNs}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "${vmiPhase}" == "Running" ]] && continue

        oc --kubeconfig="${dstKc}" patch "virtualmachine/${vmName}" -n "${vmNs}" \
            --type merge -p '{"metadata":{"finalizers":null}}' 1>/dev/null 2>/dev/null || true
        oc --kubeconfig="${dstKc}" patch "virtualmachineinstance/${vmName}" -n "${vmNs}" \
            --type merge -p '{"metadata":{"finalizers":null}}' 1>/dev/null 2>/dev/null || true

        oc --kubeconfig="${dstKc}" delete "virtualmachine/${vmName}" -n "${vmNs}" \
            --ignore-not-found --wait=false 1>/dev/null || true
        oc --kubeconfig="${dstKc}" delete "virtualmachineinstance/${vmName}" -n "${vmNs}" \
            --ignore-not-found --wait=false 1>/dev/null || true
        oc --kubeconfig="${dstKc}" delete "datavolume/${dvName}" -n "${vmNs}" \
            --ignore-not-found --wait=false 1>/dev/null || true

        typeset pvcName
        while read -r pvcName; do
            [[ -n "${pvcName}" ]] || continue
            oc --kubeconfig="${dstKc}" patch "persistentvolumeclaim/${pvcName}" -n "${vmNs}" \
                --type merge -p '{"metadata":{"finalizers":null}}' 1>/dev/null || true
            oc --kubeconfig="${dstKc}" delete "persistentvolumeclaim/${pvcName}" -n "${vmNs}" \
                --ignore-not-found --wait=false 1>/dev/null || true
        done < <(oc --kubeconfig="${dstKc}" get pvc -n "${vmNs}" -o json 2>/dev/null \
            | jq -r --arg dv "${dvName}" \
                '.items[].metadata.name | select(test("^(" + $dv + "|prime-))"))' \
            || true)

        oc --kubeconfig="${dstKc}" wait --for=delete "virtualmachineinstance/${vmName}" \
            -n "${vmNs}" --timeout=2m 1>/dev/null 2>/dev/null || true
        oc --kubeconfig="${dstKc}" wait --for=delete "virtualmachine/${vmName}" \
            -n "${vmNs}" --timeout=2m 1>/dev/null 2>/dev/null || true
        oc --kubeconfig="${dstKc}" wait --for=delete "datavolume/${dvName}" \
            -n "${vmNs}" --timeout=3m 1>/dev/null 2>/dev/null || true
    done
    true
}

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
        }' | MgmtOc create -f - --dry-run=client -o yaml --save-config | MgmtOc apply -f -
}

# WaitPlanReady — wait for Plan Ready condition.
WaitPlanReady() {
    typeset planName="${1:?}"
    MgmtOc wait "plan/${planName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PLAN_READY_TIMEOUT}"
}

# ApplyMigration — create Migration CR referencing the Plan.
ApplyMigration() {
    typeset migName="${1:?}"
    typeset planName="${2:?}"

    {
        MgmtOc create -f - --dry-run=client -o yaml --save-config
    } <<EOF | MgmtOc apply -f -
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
    MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
        || true
}

# MigrationPipelinePhase — read one pipeline step phase for a VM.
MigrationPipelinePhase() {
    typeset migName="${1:?}"
    typeset vmName="${2:?}"
    typeset stepName="${3:?}"
    typeset migJson phase

    migJson="$(MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" -o json || true)"
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
        succeededStatus="$(MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
        failedStatus="$(MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"
        msg="$(MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' || true)"

        [[ "${succeededStatus}" == "True" ]] && return 0

        if [[ "${failedStatus}" == "True" ]]; then
            MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
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

    MgmtOc get plan,migration,networkmap,storagemap,provider -n "${MTV_NAMESPACE}" \
        > "${dirDiag}/hub-mtv-resources.txt" 2>&1 || true
    MgmtOc describe "plan/${planName}" -n "${MTV_NAMESPACE}" \
        > "${dirDiag}/plan-describe.txt" 2>&1 || true
    MgmtOc describe "migration/${migName}" -n "${MTV_NAMESPACE}" \
        > "${dirDiag}/migration-describe.txt" 2>&1 || true
    MgmtOc get events -n "${MTV_NAMESPACE}" --sort-by='.lastTimestamp' \
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
    typeset fwdTargetNs="${1:-${_fwdVmNs:-${MTV_HS_HUB_VM_NAMESPACE}}}"
    typeset revTargetNs="${2:-${_revVmNs:-${MTV_HS_SPOKE_VM_NAMESPACE}}}"

    case "${cclmDirection}" in
    (both|spoke-to-hub)
        DumpDirectionDiagnostics "spoke-to-hub" \
            "${_revPlan:-${MTV_HS_SPOKE_TO_HUB_PLAN}}" "${_revMig:-${MTV_HS_SPOKE_TO_HUB_MIGRATION}}" \
            "${spokeKubeconfig}" "${KUBECONFIG}" \
            "${_revVmNs:-${MTV_HS_SPOKE_VM_NAMESPACE}}" "${revTargetNs}" \
            "${_revVmPrefix:-${MTV_HS_SPOKE_VM_PREFIX}}" || true
        ;;&
    (both|hub-to-spoke)
        DumpDirectionDiagnostics "hub-to-spoke" \
            "${_fwdPlan:-${MTV_HS_HUB_TO_SPOKE_PLAN}}" "${_fwdMig:-${MTV_HS_HUB_TO_SPOKE_MIGRATION}}" \
            "${KUBECONFIG}" "${spokeKubeconfig}" \
            "${_fwdVmNs:-${MTV_HS_HUB_VM_NAMESPACE}}" "${fwdTargetNs}" \
            "${_fwdVmPrefix:-${MTV_HS_HUB_VM_PREFIX}}" || true
        ;;
    (spoke-round-trip)
        DumpDirectionDiagnostics "spoke-to-hub" \
            "${_revPlan:-${MTV_HS_SPOKE_TO_HUB_PLAN}}" "${_revMig:-${MTV_HS_SPOKE_TO_HUB_MIGRATION}}" \
            "${spokeKubeconfig}" "${KUBECONFIG}" \
            "${_revVmNs:-${MTV_HS_SPOKE_VM_NAMESPACE}}" "${revTargetNs}" \
            "${_revVmPrefix:-${MTV_HS_SPOKE_VM_PREFIX}}" || true
        DumpDirectionDiagnostics "hub-to-spoke-return" \
            "${_fwdPlan:-${MTV_HS_HUB_TO_SPOKE_PLAN}}" "${_fwdMig:-${MTV_HS_HUB_TO_SPOKE_MIGRATION}}" \
            "${KUBECONFIG}" "${spokeKubeconfig}" \
            "${revTargetNs}" "${fwdTargetNs}" \
            "${_revVmPrefix:-${MTV_HS_SPOKE_VM_PREFIX}}" || true
        ;;
    (spoke-to-spoke)
        DumpDirectionDiagnostics "spoke-to-spoke" \
            "${_fwdPlan}" "${_fwdMig}" \
            "${spokeKubeconfig}" "${destKubeconfig}" \
            "${_fwdVmNs}" "${fwdTargetNs}" \
            "${_fwdVmPrefix}" || true
        ;;
    (spoke-round-trip-ss)
        DumpDirectionDiagnostics "spoke-to-spoke-fwd" \
            "${_fwdPlan}" "${_fwdMig}" \
            "${spokeKubeconfig}" "${destKubeconfig}" \
            "${_fwdVmNs}" "${fwdTargetNs}" \
            "${_fwdVmPrefix}" || true
        DumpDirectionDiagnostics "spoke-to-spoke-rev" \
            "${_revPlan}" "${_revMig}" \
            "${destKubeconfig}" "${spokeKubeconfig}" \
            "${fwdTargetNs}" "${revTargetNs}" \
            "${_fwdVmPrefix}" || true
        ;;
    esac
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
        MaybeEnsureDecentralizedLiveMigration "${srcKc}" "${dstKc}"
    JStep "[${direction}] Preflight: Sync Controllers Available (src + dst)" \
        MaybeWaitForSyncControllers "${srcKc}" "${dstKc}"
    JStep "[${direction}] Preflight: MTV CCLM Feature Gate Active" \
        PreflightCclm "${srcKc}" "${dstKc}"
    JStep "[${direction}] Preflight: Submariner No Globalnet" \
        MaybePreflightSubmarinerNoGlobalnet "${srcKc}" "${dstKc}"
    JStep "[${direction}] Preflight: Provider Inventory Refresh" \
        RefreshProvidersForLivePlan "${srcProvider}" "${dstProvider}"
    JStep "[${direction}] Preflight: All Source VMs Running" \
        PreflightAllSourceVmsRunning "${srcKc}" "${vmPrefix}" "${vmNs}"
    JStep "[${direction}] Preflight: CCLM Sync Port Reachable" \
        PreflightCclmSyncConnectivity "${srcKc}" "${dstKc}" "${vmPrefix}" "${vmNs}"
    JStep "[${direction}] Preflight: VM Storage Class Mapped" \
        PreflightVmStorageMapped "${srcKc}" "${vmPrefix}" "${vmNs}" "${storMapName}"

    vmsJson="$(BuildVmsJson "${vmPrefix}" "${vmNs}" "${vmCount}")"

    # Always clean up stale VM/DV/PVC on the destination before Plan creation.
    # CleanupDestinationStaleResources skips any VMI already Running (idempotent).
    # On a clean first run the oc get calls return not-found and the function no-ops;
    # on re-runs or return legs it removes leftover objects that would cause
    # MTV PrepareTarget to reject the Plan with "Target VM already exists".
    JStep "[${direction}] Pre-migration: Cleanup stale destination resources" \
        CleanupDestinationStaleResources "${dstKc}" "${vmPrefix}" "${targetNs}" "${vmCount}"

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
            MgmtOc get "plan/${planName}" "migration/${migName}" \
                -n "${MTV_NAMESPACE}" -o wide
            MgmtOc get "plan/${planName}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
            MgmtOc get "migration/${migName}" -n "${MTV_NAMESPACE}" \
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
# P2P_MIGRATION_DIRECTION controls which directions to run:
#   both              – hub→spoke then spoke→hub (default, backward-compatible)
#   hub-to-spoke      – only the hub→spoke direction
#   spoke-to-hub      – only the spoke→hub direction
#   spoke-round-trip  – spoke VMs: spoke→hub, cleanup spoke, then hub→spoke return
#   spoke-to-spoke    – spoke-1 VMs → spoke-2 (single direction; requires P2P_DEST_SPOKE_INDEX)
#   spoke-round-trip-ss – spoke-1→spoke-2, cleanup spoke-1, then spoke-2→spoke-1 return
#
# The p2p-mtv-spoke-to-hub-migration wrapper step hardcodes this to "spoke-to-hub" so it can
# appear after a spoke upgrade in the same chain without conflicting with a prior hub-to-spoke step.
typeset cclmDirection="${P2P_MIGRATION_DIRECTION:-both}"

# Generalized provider / map names — topology-agnostic aliases for spoke-spoke support.
# For hub↔spoke topologies these default to the MTV_HS_* env vars (backward-compatible).
# For spoke-spoke topologies set MTV_SRC_PROVIDER / MTV_DST_PROVIDER and MTV_FWD_* / MTV_REV_*
# in the calling chain or workflow; hub/spoke-specific names are then unused.
#
# Forward direction: source cluster → destination cluster (hub-to-spoke OR spoke-to-spoke fwd)
typeset _fwdSrcProv="${MTV_SRC_PROVIDER:-${MTV_HS_HUB_PROVIDER}}"
typeset _fwdDstProv="${MTV_DST_PROVIDER:-${MTV_HS_SPOKE_PROVIDER}}"
typeset _fwdNetMap="${MTV_FWD_NETWORK_MAP:-${MTV_HS_HUB_TO_SPOKE_NETWORK_MAP}}"
typeset _fwdStorMap="${MTV_FWD_STORAGE_MAP:-${MTV_HS_HUB_TO_SPOKE_STORAGE_MAP}}"
typeset _fwdPlan="${MTV_FWD_PLAN:-${MTV_HS_HUB_TO_SPOKE_PLAN}}"
typeset _fwdMig="${MTV_FWD_MIGRATION:-${MTV_HS_HUB_TO_SPOKE_MIGRATION}}"
typeset _fwdVmPrefix="${MTV_FWD_VM_PREFIX:-${MTV_HS_HUB_VM_PREFIX}}"
typeset _fwdVmNs="${MTV_FWD_VM_NAMESPACE:-${MTV_HS_HUB_VM_NAMESPACE}}"
# Reverse direction: destination cluster → source cluster (spoke-to-hub OR spoke-to-spoke rev)
typeset _revSrcProv="${MTV_REV_SRC_PROVIDER:-${MTV_HS_SPOKE_PROVIDER}}"
typeset _revDstProv="${MTV_REV_DST_PROVIDER:-${MTV_HS_HUB_PROVIDER}}"
typeset _revNetMap="${MTV_REV_NETWORK_MAP:-${MTV_HS_SPOKE_TO_HUB_NETWORK_MAP}}"
typeset _revStorMap="${MTV_REV_STORAGE_MAP:-${MTV_HS_SPOKE_TO_HUB_STORAGE_MAP}}"
typeset _revPlan="${MTV_REV_PLAN:-${MTV_HS_SPOKE_TO_HUB_PLAN}}"
typeset _revMig="${MTV_REV_MIGRATION:-${MTV_HS_SPOKE_TO_HUB_MIGRATION}}"
typeset _revVmPrefix="${MTV_REV_VM_PREFIX:-${MTV_HS_SPOKE_VM_PREFIX}}"
typeset _revVmNs="${MTV_REV_VM_NAMESPACE:-${MTV_HS_SPOKE_VM_NAMESPACE}}"

(
    trap OnError ERR

    [[ "${MTV_HS_PLAN_TYPE}" == "live" || "${MTV_HS_PLAN_TYPE}" == "cold" ]]
    (( vmCount >= 1 ))
    [[ "${cclmDirection}" == "both" \
    || "${cclmDirection}" == "hub-to-spoke" \
    || "${cclmDirection}" == "spoke-to-hub" \
    || "${cclmDirection}" == "spoke-round-trip" \
    || "${cclmDirection}" == "spoke-to-spoke" \
    || "${cclmDirection}" == "spoke-round-trip-ss" ]] || {
        : "ERROR: P2P_MIGRATION_DIRECTION must be one of: both, hub-to-spoke, spoke-to-hub, spoke-round-trip, spoke-to-spoke, spoke-round-trip-ss (got '${cclmDirection}')"
        exit 1
    }

    ResolveSpokeKubeconfig

    # For spoke-spoke directions the destination is a second spoke cluster, not the hub.
    if [[ "${cclmDirection}" == "spoke-to-spoke" || "${cclmDirection}" == "spoke-round-trip-ss" ]]; then
        ResolveDestKubeconfig
    else
        # For hub↔spoke topologies the destination (from the fwd leg perspective) defaults to hub.
        destKubeconfig="${KUBECONFIG}"
    fi

    hubToSpokeTargetNs="${hubToSpokeTargetNs:-${_fwdVmNs}}"
    spokeToHubTargetNs="${spokeToHubTargetNs:-${_revVmNs}}"

    MgmtOc get ns "${MTV_NAMESPACE}" 1>/dev/null

    # Hub→Spoke: forward VMs migrate from hub (source) to spoke (destination).
    if [[ "${cclmDirection}" == "hub-to-spoke" || "${cclmDirection}" == "both" ]]; then
        RunOneMigrationDirection "hub-to-spoke" \
            "${_fwdSrcProv}" "${_fwdDstProv}" \
            "${_fwdNetMap}" "${_fwdStorMap}" \
            "${_fwdPlan}" "${_fwdMig}" \
            "${_fwdVmPrefix}" "${_fwdVmNs}" "${hubToSpokeTargetNs}" \
            "${KUBECONFIG}" "${spokeKubeconfig}"
    fi

    # Spoke→Hub: reverse VMs migrate from spoke (source) back to hub (destination).
    if [[ "${cclmDirection}" == "spoke-to-hub" || "${cclmDirection}" == "both" ]]; then
        RunOneMigrationDirection "spoke-to-hub" \
            "${_revSrcProv}" "${_revDstProv}" \
            "${_revNetMap}" "${_revStorMap}" \
            "${_revPlan}" "${_revMig}" \
            "${_revVmPrefix}" "${_revVmNs}" "${spokeToHubTargetNs}" \
            "${spokeKubeconfig}" "${KUBECONFIG}"
    fi

    # Spoke-round-trip (hub↔spoke): spoke VMs start on spoke, migrate to hub, then return.
    #
    #   Leg 1 (spoke→hub): _revVmPrefix VMs from spoke (_revVmNs) → hub (spokeToHubTargetNs).
    #   Post-leg-1: clean up source spoke VM/DV/PVC so return leg has no collision.
    #   Leg 2 (hub→spoke return): same VMs (now on hub in spokeToHubTargetNs) → spoke (hubToSpokeTargetNs).
    if [[ "${cclmDirection}" == "spoke-round-trip" ]]; then
        # Leg 1: spoke → hub
        RunOneMigrationDirection "spoke-to-hub" \
            "${_revSrcProv}" "${_revDstProv}" \
            "${_revNetMap}" "${_revStorMap}" \
            "${_revPlan}" "${_revMig}" \
            "${_revVmPrefix}" "${_revVmNs}" "${spokeToHubTargetNs}" \
            "${spokeKubeconfig}" "${KUBECONFIG}"

        JStep "[spoke-round-trip] Post-leg-1: Cleanup source spoke VM resources" \
            CleanupDestinationStaleResources \
                "${spokeKubeconfig}" "${_revVmPrefix}" \
                "${_revVmNs}" "${vmCount}"

        # Leg 2: hub → spoke return (same VMs, now in spokeToHubTargetNs on hub)
        RunOneMigrationDirection "hub-to-spoke-return" \
            "${_fwdSrcProv}" "${_fwdDstProv}" \
            "${_fwdNetMap}" "${_fwdStorMap}" \
            "${_fwdPlan}" "${_fwdMig}" \
            "${_revVmPrefix}" "${spokeToHubTargetNs}" "${hubToSpokeTargetNs}" \
            "${KUBECONFIG}" "${spokeKubeconfig}"
    fi

    # Spoke-to-spoke: spoke-1 VMs → spoke-2 (single direction).
    # Requires P2P_DEST_SPOKE_INDEX (or P2P_DEST_KUBECONFIG) to identify spoke-2.
    # MTV management plane (MgmtOc / KUBECONFIG) remains the ACM hub regardless of topology.
    if [[ "${cclmDirection}" == "spoke-to-spoke" ]]; then
        RunOneMigrationDirection "spoke-to-spoke" \
            "${_fwdSrcProv}" "${_fwdDstProv}" \
            "${_fwdNetMap}" "${_fwdStorMap}" \
            "${_fwdPlan}" "${_fwdMig}" \
            "${_fwdVmPrefix}" "${_fwdVmNs}" "${hubToSpokeTargetNs}" \
            "${spokeKubeconfig}" "${destKubeconfig}"
    fi

    # Spoke-round-trip-ss: spoke-1 VMs → spoke-2, cleanup spoke-1, then spoke-2 → spoke-1 return.
    # Requires P2P_DEST_SPOKE_INDEX (or P2P_DEST_KUBECONFIG) to identify spoke-2.
    if [[ "${cclmDirection}" == "spoke-round-trip-ss" ]]; then
        # Leg 1: spoke-1 → spoke-2
        RunOneMigrationDirection "spoke-to-spoke-fwd" \
            "${_fwdSrcProv}" "${_fwdDstProv}" \
            "${_fwdNetMap}" "${_fwdStorMap}" \
            "${_fwdPlan}" "${_fwdMig}" \
            "${_fwdVmPrefix}" "${_fwdVmNs}" "${hubToSpokeTargetNs}" \
            "${spokeKubeconfig}" "${destKubeconfig}"

        JStep "[spoke-round-trip-ss] Post-leg-1: Cleanup spoke-1 source VM resources" \
            CleanupDestinationStaleResources \
                "${spokeKubeconfig}" "${_fwdVmPrefix}" \
                "${_fwdVmNs}" "${vmCount}"

        # Leg 2: spoke-2 → spoke-1 return (same VMs, now in hubToSpokeTargetNs on spoke-2)
        RunOneMigrationDirection "spoke-to-spoke-rev" \
            "${_revSrcProv}" "${_revDstProv}" \
            "${_revNetMap}" "${_revStorMap}" \
            "${_revPlan}" "${_revMig}" \
            "${_fwdVmPrefix}" "${hubToSpokeTargetNs}" "${spokeToHubTargetNs}" \
            "${destKubeconfig}" "${spokeKubeconfig}"
    fi

    true
) || cclmStepRc=$?

WriteJunit

if (( cclmStepRc != 0 )); then
    DumpDiagnostics "${hubToSpokeTargetNs:-${_fwdVmNs:-${MTV_HS_HUB_VM_NAMESPACE}}}" \
                    "${spokeToHubTargetNs:-${_revVmNs:-${MTV_HS_SPOKE_VM_NAMESPACE}}}"
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-mtv-execute-hub-spoke-migration failed (rc=${cclmStepRc}); not failing job (debug mode)"
    else
        exit "${cclmStepRc}"
    fi
fi

true
