#!/bin/bash
#
# Cold VM migration POC: create N CNV VMs on spoke-1, stop them, then migrate
# all in a single MTV Plan (type=cold) to spoke-2.
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

typeset -i vmCount="${MTV_COLD_VM_COUNT}"
typeset vmBaseName="${MTV_COLD_VM_BASE_NAME}"
typeset vmNamespace="${MTV_TEST_VM_NAMESPACE}"
typeset targetNs="${MTV_TEST_VM_TARGET_NAMESPACE:-${vmNamespace}}"
typeset -i spokeSourceIndex="${MTV_SOURCE_SPOKE_INDEX}"
typeset -i spokeDestIndex="${MTV_DEST_SPOKE_INDEX}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"

typeset sourceKubeconfig="" destKubeconfig="" junitFile=""

# Build VM names array: <base>-1, <base>-2, ..., <base>-N
typeset -a vmNamesArr=()
for (( i=1; i<=vmCount; i++ )); do
    vmNamesArr+=("${vmBaseName}-${i}")
done

# SourceOc / DestOc / HubOc — target specific clusters.
SourceOc() { oc --kubeconfig="${sourceKubeconfig}" "$@"; }
DestOc()   { oc --kubeconfig="${destKubeconfig}"   "$@"; }
HubOc()    { oc "$@"; }

# ResolveSpokeKubeconfigs — resolve source and dest spoke kubeconfigs from SHARED_DIR.
ResolveSpokeKubeconfigs() {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -n "${MTV_SOURCE_SPOKE_KUBECONFIG}" ]]; then
        sourceKubeconfig="${MTV_SOURCE_SPOKE_KUBECONFIG}"
    else
        sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${spokeSourceIndex}"
        if [[ ! -r "${sourceKubeconfig}" && spokeSourceIndex -eq 1 && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
            sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
        fi
    fi

    if [[ -n "${MTV_DEST_SPOKE_KUBECONFIG}" ]]; then
        destKubeconfig="${MTV_DEST_SPOKE_KUBECONFIG}"
    else
        destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${spokeDestIndex}"
    fi

    [[ -r "${sourceKubeconfig}" ]]
    [[ -r "${destKubeconfig}" ]]
}

# DumpDiagnostics — write diagnostics on failure.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/cold-multi-migration-diagnostics"
    mkdir -p "${diagDir}"
    typeset vmName
    for vmName in "${vmNamesArr[@]}"; do
        {
            SourceOc get "virtualmachine/${vmName}" \
                "datavolume/${vmName}-rootdisk" \
                -n "${vmNamespace}" -o yaml 2>&1 || true
            SourceOc get events -n "${vmNamespace}" \
                --sort-by='.lastTimestamp' 2>&1 || true
        } > "${diagDir}/source-vm-${vmName}.yaml" 2>&1 || true
    done
    HubOc get "plan/${MTV_PLAN_NAME}" \
        -n "${MTV_NAMESPACE}" -o yaml > "${diagDir}/plan.yaml" 2>&1 || true
    HubOc get "migration/${MTV_MIGRATION_NAME}" \
        -n "${MTV_NAMESPACE}" -o yaml > "${diagDir}/migration.yaml" 2>&1 || true
    HubOc get events -n "${MTV_NAMESPACE}" \
        --sort-by='.lastTimestamp' > "${diagDir}/mtv-namespace-events.txt" 2>&1 || true
}

# OnError — dump diagnostics before propagating failure.
OnError() {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# EnsureVmNamespace — create source namespace if absent.
EnsureVmNamespace() {
    yq e '.metadata.name = strenv(MTV_TEST_VM_NAMESPACE)' - <<'YAML' | SourceOc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: placeholder
  labels:
    app.kubernetes.io/part-of: vm-migration-test
YAML
}

# ApplyDataVolume — cirros HTTP-import DataVolume for one VM.
ApplyDataVolume() {
    typeset vmName="${1:?}"
    typeset dvName="${vmName}-rootdisk"

    VM_NAME="${vmName}" DV_NAME="${dvName}" yq e '
        .metadata.name                              = strenv(DV_NAME) |
        .metadata.namespace                         = strenv(MTV_TEST_VM_NAMESPACE) |
        .metadata.labels["app.kubernetes.io/name"]  = strenv(VM_NAME) |
        .spec.source.http.url                       = strenv(CNV_TEST_VM_CIRROS_IMAGE_URL) |
        .spec.storage.resources.requests.storage    = strenv(CNV_TEST_VM_DISK_SIZE) |
        .spec.storage.storageClassName               = strenv(CNV_TEST_VM_STORAGE_CLASS)
    ' - <<'YAML' | SourceOc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: placeholder
  namespace: placeholder
  labels:
    app.kubernetes.io/name: placeholder
    vm.kubevirt.io/image: cirros
  annotations:
    cdi.kubevirt.io/storage.usePopulator: "false"
spec:
  source:
    http:
      url: placeholder
  storage:
    accessModes:
    - ReadWriteMany
    volumeMode: Block
    resources:
      requests:
        storage: placeholder
    storageClassName: placeholder
YAML
}

# WaitDataVolumeReady — wait for DV Ready condition.
WaitDataVolumeReady() {
    typeset vmName="${1:?}"
    SourceOc wait "datavolume/${vmName}-rootdisk" -n "${vmNamespace}" \
        --for=condition=Ready --timeout="${CNV_TEST_VM_DATAVOLUME_WAIT_TIMEOUT}"
}

# ApplyVirtualMachine — minimal cirros VM for cold migration testing.
ApplyVirtualMachine() {
    typeset vmName="${1:?}"
    typeset dvName="${vmName}-rootdisk"

    VM_NAME="${vmName}" DV_NAME="${dvName}" yq e '
        .metadata.name                                        = strenv(VM_NAME) |
        .metadata.namespace                                   = strenv(MTV_TEST_VM_NAMESPACE) |
        .metadata.labels["app.kubernetes.io/name"]            = strenv(VM_NAME) |
        .metadata.labels["vm.kubevirt.io/name"]               = strenv(VM_NAME) |
        .spec.template.metadata.labels["vm.kubevirt.io/name"] = strenv(VM_NAME) |
        .spec.template.spec.domain.cpu.cores                  = (strenv(CNV_TEST_VM_CPUS) | tonumber) |
        .spec.template.spec.domain.memory.guest               = strenv(CNV_TEST_VM_MEMORY) |
        .spec.template.spec.volumes[0].dataVolume.name        = strenv(DV_NAME)
    ' - <<'YAML' | SourceOc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: placeholder
  namespace: placeholder
  labels:
    app.kubernetes.io/name: placeholder
    vm.kubevirt.io/name: placeholder
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        vm.kubevirt.io/name: placeholder
    spec:
      domain:
        cpu:
          cores: 1
        memory:
          guest: placeholder
        devices:
          disks:
          - name: rootdisk
            bootOrder: 1
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
        machine:
          type: pc-q35-rhel9.4.0
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: placeholder
      terminationGracePeriodSeconds: 180
      evictionStrategy: None
YAML
}

# WaitVmiRunning — wait for VMI to appear then reach Running phase.
WaitVmiRunning() {
    typeset vmName="${1:?}"
    (
        SECONDS=0
        while (( SECONDS < 120 )); do
            SourceOc get "virtualmachineinstance/${vmName}" \
                -n "${vmNamespace}" 1>/dev/null && exit 0
            sleep 2
        done
        : "VMI ${vmName} not found in ${vmNamespace} after 120s" >&2
        exit 1
    )
    SourceOc wait "virtualmachineinstance/${vmName}" -n "${vmNamespace}" \
        --for=jsonpath='{.status.phase}'=Running \
        --timeout="${CNV_TEST_VM_VMI_WAIT_TIMEOUT}"
}

# StopVirtualMachine — patch runStrategy to Halted.
StopVirtualMachine() {
    typeset vmName="${1:?}"
    SourceOc patch "virtualmachine/${vmName}" -n "${vmNamespace}" \
        --type merge -p '{"spec":{"runStrategy":"Halted"}}' 1>/dev/null
}

# WaitVmiDeleted — wait for VMI to disappear after stop.
WaitVmiDeleted() {
    typeset vmName="${1:?}"
    SourceOc wait "virtualmachineinstance/${vmName}" -n "${vmNamespace}" \
        --for=delete --timeout="${CNV_TEST_VM_STOP_TIMEOUT}" 1>/dev/null || true

    # Confirm VM printableStatus is Stopped.
    (
        SECONDS=0
        typeset -i wMax=120
        typeset vmStatus=""
        while (( SECONDS < wMax )); do
            vmStatus="$(SourceOc get "virtualmachine/${vmName}" \
                -n "${vmNamespace}" \
                -o jsonpath='{.status.printableStatus}' || true)"
            [[ "${vmStatus}" == "Stopped" ]] && exit 0
            : "Waiting VM ${vmName} Stopped (${SECONDS}/${wMax}s): ${vmStatus}"
            sleep 5
        done
        : "Timed out waiting for VM ${vmName} Stopped (last: ${vmStatus})" >&2
        exit 1
    )
}

# BuildPlanVmsJson — produce JSON array of {name, namespace} for all VMs.
BuildPlanVmsJson() {
    typeset vmName
    for vmName in "${vmNamesArr[@]}"; do
        jq -cn --arg name "${vmName}" --arg ns "${vmNamespace}" \
            '{name: $name, namespace: $ns}'
    done | jq -sc '.'
}

# ApplyMultiVmPlan — create MTV Plan with all N VMs via jq data marshalling.
ApplyMultiVmPlan() {
    typeset vmsJson
    vmsJson="$(BuildPlanVmsJson)"

    {
        jq -cn \
            --arg planName  "${MTV_PLAN_NAME}" \
            --arg ns        "${MTV_NAMESPACE}" \
            --arg srcProv   "${MTV_SOURCE_PROVIDER}" \
            --arg dstProv   "${MTV_DESTINATION_PROVIDER}" \
            --arg targetNs  "${targetNs}" \
            --arg netMap    "${MTV_NETWORK_MAP_NAME}" \
            --arg stMap     "${MTV_STORAGE_MAP_NAME}" \
            --argjson vms   "${vmsJson}" \
            '{
                apiVersion: "forklift.konveyor.io/v1beta1",
                kind: "Plan",
                metadata: {name: $planName, namespace: $ns},
                spec: {
                    provider: {
                        source:      {name: $srcProv, namespace: $ns},
                        destination: {name: $dstProv, namespace: $ns}
                    },
                    targetNamespace: $targetNs,
                    map: {
                        network: {name: $netMap, namespace: $ns},
                        storage: {name: $stMap,  namespace: $ns}
                    },
                    vms: $vms,
                    type: "cold"
                }
            }' |
        yq -p json -o yaml |
        HubOc create -f - --dry-run=client -o yaml --save-config
    } | HubOc apply -f -
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

# ParseOcWaitDurationSeconds — convert oc wait duration string to integer seconds.
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

# PrintMigrationPipeline — log per-VM migration pipeline phases.
PrintMigrationPipeline() {
    HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
        || true
}

# WaitMigrationSucceeded — poll until all VMs migrated (Succeeded) or Failed.
WaitMigrationSucceeded() {
    typeset -i deadline
    typeset succeededStatus failedStatus
    typeset -i pollInterval="${MTV_MIGRATION_POLL_INTERVAL_SECONDS}"

    deadline=$(( SECONDS + $(ParseOcWaitDurationSeconds "${MTV_MIGRATION_TIMEOUT}") ))

    while (( SECONDS < deadline )); do
        succeededStatus="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
        failedStatus="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"

        [[ "${succeededStatus}" == "True" ]] && return 0

        if [[ "${failedStatus}" == "True" ]]; then
            HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' \
                1>&2 || true
            PrintMigrationPipeline 1>&2
            false
        fi

        PrintMigrationPipeline
        : "Migration in progress (${SECONDS}/${deadline}s)"
        sleep "${pollInterval}"
    done

    false
}

# VerifyAllVmsOnDest — all migrated VMs must reach Running on destination.
VerifyAllVmsOnDest() {
    typeset vmName destPhase
    typeset -i passCount=0

    for vmName in "${vmNamesArr[@]}"; do
        destPhase="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
            -o jsonpath='{.status.phase}' || true)"
        if [[ "${destPhase}" == "Running" ]]; then
            (( passCount++ )) || true
        else
            : "VM ${vmName} on destination is not Running (phase=${destPhase})" >&2
            false
        fi
    done

    : "All ${passCount}/${vmCount} VMs verified Running on destination"
}

# JStep — run a function and record PASS/FAIL to junitFile (no-op if junitFile unset).
JStep() {
    typeset stepName="${1:?}"; shift
    typeset -i t0=$SECONDS rc=0
    "$@" || rc=$?
    typeset -i elapsed=$(( SECONDS - t0 ))
    if [[ -n "${junitFile}" ]]; then
        if (( rc == 0 )); then
            printf 'PASS\t%s\t%d\t\n' "${stepName}" "${elapsed}" >> "${junitFile}"
        else
            printf 'FAIL\t%s\t%d\tFailed (rc=%d); see diagnostics in cold-multi-migration-diagnostics/\n' \
                "${stepName}" "${elapsed}" "${rc}" >> "${junitFile}"
        fi
    fi
    return "${rc}"
}

# WriteJunit — emit JUnit XML from junitFile records.
WriteJunit() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    [[ -f "${junitFile}" ]] || return 0

    typeset xmlFile="${ARTIFACT_DIR}/junit_cold_vm_multi_migration.xml"
    mkdir -p "${ARTIFACT_DIR}"

    typeset -i total=0 failures=0 totalTime=0
    typeset status stepName elapsed failMsg

    while IFS=$'\t' read -r status stepName elapsed failMsg; do
        (( total++ )) || true
        (( totalTime += elapsed )) || true
        [[ "${status}" == "FAIL" ]] && (( failures++ )) || true
    done < "${junitFile}"

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuite name="cold-vm-multi-migration" tests="%d" failures="%d" errors="0" skipped="0" time="%d">\n' \
            "${total}" "${failures}" "${totalTime}"
        while IFS=$'\t' read -r status stepName elapsed failMsg; do
            printf '  <testcase name="%s" classname="cold-vm-multi-migration" time="%d">\n' \
                "${stepName}" "${elapsed}"
            if [[ "${status}" == "FAIL" ]]; then
                printf '    <failure message="%s">%s</failure>\n' \
                    "${failMsg}" "${failMsg}"
            fi
            printf '  </testcase>\n'
        done < "${junitFile}"
        printf '</testsuite>\n'
    } > "${xmlFile}"

    : "JUnit XML written → ${xmlFile} (${total} tests, ${failures} failures)"
    rm -f "${junitFile}"
}

# ---

trap - ERR

if [[ -n "${ARTIFACT_DIR}" ]]; then
    mkdir -p "${ARTIFACT_DIR}"
    junitFile="$(mktemp "${ARTIFACT_DIR}/cold-multi-migration-junit.XXXXXX")"
fi

typeset -i stepRc=0
(
    trap OnError ERR

    ResolveSpokeKubeconfigs

    (( vmCount >= 1 ))

    EnsureVmNamespace

    # Phase 1: Create DataVolumes for all VMs.
    typeset vmName
    for vmName in "${vmNamesArr[@]}"; do
        ApplyDataVolume "${vmName}"
    done

    # Phase 2: Wait for all DVs ready (sequential to keep logs readable).
    for vmName in "${vmNamesArr[@]}"; do
        JStep "DataVolume Ready: ${vmName}" WaitDataVolumeReady "${vmName}"
    done

    # Phase 3: Create all VMs (started via runStrategy: Always).
    for vmName in "${vmNamesArr[@]}"; do
        ApplyVirtualMachine "${vmName}"
    done

    # Phase 4: Wait for all VMIs Running.
    for vmName in "${vmNamesArr[@]}"; do
        JStep "VMI Running: ${vmName}" WaitVmiRunning "${vmName}"
    done

    # Phase 5: Stop all VMs (cold migration requires powered-off VMs).
    for vmName in "${vmNamesArr[@]}"; do
        StopVirtualMachine "${vmName}"
    done
    for vmName in "${vmNamesArr[@]}"; do
        JStep "VM Stopped: ${vmName}" WaitVmiDeleted "${vmName}"
    done

    # Phase 6: Create single MTV Plan with all N VMs and run Migration.
    JStep "Migration: Apply Plan (${vmCount} VMs)"  ApplyMultiVmPlan
    JStep "Migration: Plan Ready"                   WaitPlanReady
    JStep "Migration: Apply Migration"              ApplyMigration
    JStep "Migration: Succeeded"                    WaitMigrationSucceeded
    JStep "Verification: All VMs Running on Dest"   VerifyAllVmsOnDest

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        {
            HubOc get "plan/${MTV_PLAN_NAME}" \
                "migration/${MTV_MIGRATION_NAME}" \
                -n "${MTV_NAMESPACE}" -o wide
            PrintMigrationPipeline
            for vmName in "${vmNamesArr[@]}"; do
                SourceOc get "virtualmachine/${vmName}" \
                    -n "${vmNamespace}" -o wide || true
                DestOc get "virtualmachine/${vmName}" \
                    -n "${targetNs}" -o wide || true
            done
        } > "${ARTIFACT_DIR}/cold-multi-migration-status.txt"
    fi
    true
) || stepRc=$?

WriteJunit

if (( stepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-cold-vm-multi-migration failed (rc=${stepRc}); not failing job (debug mode)"
    else
        exit "${stepRc}"
    fi
fi

true
