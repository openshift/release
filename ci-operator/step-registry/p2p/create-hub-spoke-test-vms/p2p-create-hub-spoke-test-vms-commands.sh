#!/bin/bash
#
# Create multiple CNV test VMs on the ACM hub and on a spoke cluster for hub↔spoke MTV live
# migration testing.
#
# Creates P2P_HS_VM_COUNT VMs on the hub (prefix P2P_HS_HUB_VM_PREFIX, using KUBECONFIG)
# and P2P_HS_VM_COUNT VMs on the spoke (prefix P2P_HS_SPOKE_VM_PREFIX, using SHARED_DIR
# kubeconfig). Hub VMs will be migrated hub→spoke; spoke VMs will be migrated spoke→hub.
#
# Both sets use ODF RWX block storage. RHEL DataSource clones require cloneStrategy=copy
# and cdi.kubevirt.io/storage.usePopulator=false to avoid prime-* ClaimMisbound failures.
#
# Requires CNV (KubeVirt/HCO) and ODF installed on both the hub and the spoke.
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

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -i vmCount="${P2P_HS_VM_COUNT}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
typeset spokeKubeconfig=""
typeset diagDir=""

# ResolveSpokeKubeconfig — resolve spoke kubeconfig from explicit env or SHARED_DIR index.
ResolveSpokeKubeconfig() {
    [[ -n "${SHARED_DIR}" ]]

    if [[ -n "${P2P_HS_SPOKE_KUBECONFIG}" ]]; then
        spokeKubeconfig="${P2P_HS_SPOKE_KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_HS_SPOKE_INDEX}" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_HS_SPOKE_INDEX}"
    elif [[ "${P2P_HS_SPOKE_INDEX}" == "1" && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
        : "Spoke kubeconfig not found for index ${P2P_HS_SPOKE_INDEX}" >&2
        return 1
    fi
    [[ -r "${spokeKubeconfig}" ]]
}

# EnsureNamespace — idempotently create the test VM namespace on a cluster.
EnsureNamespace() {
    typeset kc="${1:?}"
    typeset ns="${2:?}"

    NS_NAME="${ns}" yq e '.metadata.name = strenv(NS_NAME)' - <<'YAML' | oc --kubeconfig="${kc}" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: placeholder
  labels:
    app.kubernetes.io/part-of: vm-migration-test
YAML
}

# EnsureStorageProfileCloneStrategyCopy — ODF virt SC needs host-assisted copy for RHEL clones.
EnsureStorageProfileCloneStrategyCopy() {
    typeset kc="${1:?}"
    typeset sc="${2:?}"
    typeset spName profileCloneStrategy

    oc --kubeconfig="${kc}" get "storageclass/${sc}" 1>/dev/null
    oc --kubeconfig="${kc}" annotate "storageclass/${sc}" \
        cdi.kubevirt.io/clone-strategy=copy --overwrite 1>/dev/null

    spName="storageprofile.cdi.kubevirt.io/${sc}"
    if ! oc --kubeconfig="${kc}" get "${spName}" 1>/dev/null; then
        return 0
    fi

    profileCloneStrategy="$(oc --kubeconfig="${kc}" get "${spName}" \
        -o jsonpath='{.spec.cloneStrategy}' || true)"
    if [[ "${profileCloneStrategy}" != "copy" ]]; then
        oc --kubeconfig="${kc}" patch "${spName}" --type merge -p '{"spec":{"cloneStrategy":"copy"}}'
    fi
}

# CleanupVm — remove stale VM/DV/prime-* PVCs before recreate.
CleanupVm() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"
    typeset dvName="${vmName}-rootdisk"
    typeset pvcName

    oc --kubeconfig="${kc}" delete "virtualmachine/${vmName}" \
        -n "${ns}" --ignore-not-found --wait=false
    oc --kubeconfig="${kc}" delete "virtualmachineinstance/${vmName}" \
        -n "${ns}" --ignore-not-found --wait=false
    oc --kubeconfig="${kc}" delete "datavolume/${dvName}" \
        -n "${ns}" --ignore-not-found --wait=false

    while read -r pvcName; do
        [[ -n "${pvcName}" ]] || continue
        oc --kubeconfig="${kc}" patch "persistentvolumeclaim/${pvcName}" \
            -n "${ns}" --type merge \
            -p '{"metadata":{"finalizers":null}}' 1>/dev/null || true
        oc --kubeconfig="${kc}" delete "persistentvolumeclaim/${pvcName}" \
            -n "${ns}" --ignore-not-found --wait=false
    done < <(oc --kubeconfig="${kc}" get pvc -n "${ns}" -o json \
        | jq -r --arg dv "${dvName}" \
            '.items[].metadata.name | select(test("^(" + $dv + "|prime-))"))' \
        || true)

    oc --kubeconfig="${kc}" wait --for=delete "datavolume/${dvName}" \
        -n "${ns}" --timeout=5m 1>/dev/null || true
}

# ApplyCirrosDataVolume — HTTP import (no DataSource clone; fast and reliable).
ApplyCirrosDataVolume() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset dvName="${3:?}"
    typeset ns="${4:?}"
    typeset sc="${5:?}"

    DV_NAME="${dvName}" VM_NS="${ns}" VM_SC="${sc}" yq e '
        .metadata.name                              = strenv(DV_NAME) |
        .metadata.namespace                         = strenv(VM_NS) |
        .metadata.labels["app.kubernetes.io/name"]  = strenv(vmName) |
        .spec.source.http.url                       = strenv(P2P_HS_VM_CIRROS_IMAGE_URL) |
        .spec.storage.resources.requests.storage    = strenv(P2P_HS_VM_DISK_SIZE) |
        .spec.storage.storageClassName               = strenv(VM_SC)
    ' - <<'YAML' | oc --kubeconfig="${kc}" apply -f -
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

# ApplyRhelDataVolume — clone from CNV DataSource (requires cloneStrategy=copy on ODF).
ApplyRhelDataVolume() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset dvName="${3:?}"
    typeset ns="${4:?}"
    typeset sc="${5:?}"
    typeset dsName="${6:?}"
    typeset dsNs="${7:?}"

    oc --kubeconfig="${kc}" get "datasource/${dsName}" -n "${dsNs}" 1>/dev/null
    EnsureStorageProfileCloneStrategyCopy "${kc}" "${sc}"

    DV_NAME="${dvName}" VM_NS="${ns}" VM_SC="${sc}" \
    DS_NAME="${dsName}" DS_NS="${dsNs}" \
    yq e '
        .metadata.name                              = strenv(DV_NAME) |
        .metadata.namespace                         = strenv(VM_NS) |
        .metadata.labels["app.kubernetes.io/name"]  = strenv(vmName) |
        .spec.sourceRef.name                        = strenv(DS_NAME) |
        .spec.sourceRef.namespace                   = strenv(DS_NS) |
        .spec.storage.resources.requests.storage    = strenv(P2P_HS_VM_DISK_SIZE) |
        .spec.storage.storageClassName               = strenv(VM_SC)
    ' - <<'YAML' | oc --kubeconfig="${kc}" apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: placeholder
  namespace: placeholder
  labels:
    app.kubernetes.io/name: placeholder
    vm.kubevirt.io/image: rhel
  annotations:
    cdi.kubevirt.io/storage.usePopulator: "false"
spec:
  sourceRef:
    kind: DataSource
    name: placeholder
    namespace: placeholder
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

# ApplyCirrosVirtualMachine — minimal VM without cloud-init disk.
ApplyCirrosVirtualMachine() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset dvName="${3:?}"
    typeset ns="${4:?}"

    DV_NAME="${dvName}" VM_NS="${ns}" yq e '
        .metadata.name                                        = strenv(vmName) |
        .metadata.namespace                                   = strenv(VM_NS) |
        .metadata.labels["app.kubernetes.io/name"]            = strenv(vmName) |
        .metadata.labels["vm.kubevirt.io/name"]               = strenv(vmName) |
        .spec.template.metadata.labels["vm.kubevirt.io/name"] = strenv(vmName) |
        .spec.template.spec.domain.cpu.cores                  = (strenv(P2P_HS_VM_CPUS) | tonumber) |
        .spec.template.spec.domain.memory.guest               = strenv(P2P_HS_VM_MEMORY) |
        .spec.template.spec.volumes[0].dataVolume.name        = strenv(DV_NAME)
    ' - <<'YAML' | oc --kubeconfig="${kc}" apply -f -
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
      evictionStrategy: LiveMigrate
YAML
}

# ApplyRhelVirtualMachine — RHEL VM with cloud-init (password not logged).
ApplyRhelVirtualMachine() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset dvName="${3:?}"
    typeset ns="${4:?}"
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    typeset _userData
    _userData="$(printf '#cloud-config\nuser: cloud-user\npassword: migration123\nchpasswd:\n  expire: false\nssh_pwauth: true\nruncmd:\n- echo "VM %s is ready for migration testing" > /tmp/vm-ready.txt\n' \
        "${vmName}")"

    DV_NAME="${dvName}" VM_NS="${ns}" \
    CLOUD_INIT_USERDATA="${_userData}" \
    yq e '
        .metadata.name                                        = strenv(vmName) |
        .metadata.namespace                                   = strenv(VM_NS) |
        .metadata.labels["app.kubernetes.io/name"]            = strenv(vmName) |
        .metadata.labels["vm.kubevirt.io/name"]               = strenv(vmName) |
        .spec.template.metadata.labels["vm.kubevirt.io/name"] = strenv(vmName) |
        .spec.template.spec.domain.cpu.cores                  = (strenv(P2P_HS_VM_CPUS) | tonumber) |
        .spec.template.spec.domain.memory.guest               = strenv(P2P_HS_VM_MEMORY) |
        .spec.template.spec.volumes[0].dataVolume.name        = strenv(DV_NAME) |
        .spec.template.spec.volumes[1].cloudInitNoCloud.userData = strenv(CLOUD_INIT_USERDATA)
    ' - <<'YAML' | oc --kubeconfig="${kc}" apply -f -
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
          sockets: 1
          threads: 1
        memory:
          guest: placeholder
        devices:
          disks:
          - name: rootdisk
            bootOrder: 1
            disk:
              bus: virtio
          - name: cloudinit
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
        features:
          acpi: {}
        machine:
          type: pc-q35-rhel9.4.0
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: placeholder
      - name: cloudinit
        cloudInitNoCloud:
          userData: placeholder
      terminationGracePeriodSeconds: 180
      evictionStrategy: LiveMigrate
YAML
    [[ "${_wasTracing}" == "true" ]] && set -x
}

# WaitVmiRunning — wait for VMI object to exist then Running phase.
WaitVmiRunning() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"

    (
        SECONDS=0
        while (( SECONDS < 120 )); do
            oc --kubeconfig="${kc}" get "virtualmachineinstance/${vmName}" \
                -n "${ns}" 1>/dev/null && exit 0
            sleep 2
        done
        : "VMI ${vmName} not found in ${ns} after 120s" >&2
        exit 1
    )

    oc --kubeconfig="${kc}" wait "virtualmachineinstance/${vmName}" \
        -n "${ns}" \
        --for=jsonpath='{.status.phase}'=Running \
        --timeout="${P2P_HS_VM_VMI_WAIT_TIMEOUT}"
}

# CreateOneVm — create DataVolume + VirtualMachine for a single test VM.
CreateOneVm() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"
    typeset sc="${4:?}"
    typeset dsName="${5:?}"
    typeset dsNs="${6:?}"
    typeset dvName="${vmName}-rootdisk"

    EnsureNamespace "${kc}" "${ns}"

    if [[ "${P2P_HS_VM_CLEAN}" == "true" ]] || \
        oc --kubeconfig="${kc}" get "datavolume/${dvName}" -n "${ns}" \
            -o jsonpath='{.status.phase}' 2>/dev/null | grep -qE 'Failed|Lost'; then
        CleanupVm "${kc}" "${vmName}" "${ns}"
    fi

    case "${P2P_HS_VM_IMAGE_TYPE}" in
        cirros) ApplyCirrosDataVolume "${kc}" "${vmName}" "${dvName}" "${ns}" "${sc}" ;;
        rhel)   ApplyRhelDataVolume   "${kc}" "${vmName}" "${dvName}" "${ns}" "${sc}" "${dsName}" "${dsNs}" ;;
    esac

    oc --kubeconfig="${kc}" wait "datavolume/${dvName}" -n "${ns}" \
        --for=condition=Ready --timeout="${P2P_HS_VM_DATAVOLUME_WAIT_TIMEOUT}"

    case "${P2P_HS_VM_IMAGE_TYPE}" in
        cirros) ApplyCirrosVirtualMachine "${kc}" "${vmName}" "${dvName}" "${ns}" ;;
        rhel)   ApplyRhelVirtualMachine   "${kc}" "${vmName}" "${dvName}" "${ns}" ;;
    esac

    WaitVmiRunning "${kc}" "${vmName}" "${ns}"
}

# CreateClusterVms — create all VMs for one cluster (hub or spoke).
CreateClusterVms() {
    typeset kc="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset ns="${3:?}"
    typeset sc="${4:?}"
    typeset dsName="${5:?}"
    typeset dsNs="${6:?}"
    typeset clusterLabel="${7:?}"
    typeset -i i

    oc --kubeconfig="${kc}" get crd virtualmachines.kubevirt.io 1>/dev/null
    oc --kubeconfig="${kc}" get "storageclass/${sc}" 1>/dev/null

    for ((i = 1; i <= vmCount; i++)); do
        typeset vmName="${vmPrefix}-${i}"
        : "Creating ${clusterLabel} VM ${i}/${vmCount}: ${vmName}"
        CreateOneVm "${kc}" "${vmName}" "${ns}" "${sc}" "${dsName}" "${dsNs}"
    done
}

# DumpDiagnostics — write VM/DV state on failure.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    diagDir="${ARTIFACT_DIR}/hub-spoke-vm-create-diagnostics"
    mkdir -p "${diagDir}"
    typeset -i i

    for ((i = 1; i <= vmCount; i++)); do
        {
            oc --kubeconfig="${KUBECONFIG}" get \
                "datavolume/${P2P_HS_HUB_VM_PREFIX}-${i}-rootdisk" \
                "persistentvolumeclaim/${P2P_HS_HUB_VM_PREFIX}-${i}-rootdisk" \
                -n "${P2P_HS_VM_NAMESPACE}" -o wide
        } > "${diagDir}/hub-vm-${i}-storage.txt" 2>&1 || true
        {
            oc --kubeconfig="${spokeKubeconfig}" get \
                "datavolume/${P2P_HS_SPOKE_VM_PREFIX}-${i}-rootdisk" \
                "persistentvolumeclaim/${P2P_HS_SPOKE_VM_PREFIX}-${i}-rootdisk" \
                -n "${P2P_HS_VM_NAMESPACE}" -o wide
        } > "${diagDir}/spoke-vm-${i}-storage.txt" 2>&1 || true
    done
    oc --kubeconfig="${KUBECONFIG}" get events -n "${P2P_HS_VM_NAMESPACE}" \
        --sort-by='.lastTimestamp' > "${diagDir}/hub-events.txt" 2>&1 || true
    oc --kubeconfig="${spokeKubeconfig}" get events -n "${P2P_HS_VM_NAMESPACE}" \
        --sort-by='.lastTimestamp' > "${diagDir}/spoke-events.txt" 2>&1 || true
}

# OnError — dump diagnostics before propagating failure.
OnError() {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

trap - ERR

typeset -i cclmStepRc=0
(
    trap OnError ERR

    [[ "${P2P_HS_VM_IMAGE_TYPE}" == "cirros" || "${P2P_HS_VM_IMAGE_TYPE}" == "rhel" ]]
    (( vmCount >= 1 ))

    ResolveSpokeKubeconfig

    # Create VMs on hub (hub→spoke migration sources).
    CreateClusterVms \
        "${KUBECONFIG}" \
        "${P2P_HS_HUB_VM_PREFIX}" \
        "${P2P_HS_VM_NAMESPACE}" \
        "${P2P_HS_HUB_STORAGE_CLASS}" \
        "${P2P_HS_VM_DATA_SOURCE_NAME}" \
        "${P2P_HS_VM_DATA_SOURCE_NAMESPACE}" \
        "hub"

    # Create VMs on spoke (spoke→hub migration sources).
    CreateClusterVms \
        "${spokeKubeconfig}" \
        "${P2P_HS_SPOKE_VM_PREFIX}" \
        "${P2P_HS_VM_NAMESPACE}" \
        "${P2P_HS_SPOKE_STORAGE_CLASS}" \
        "${P2P_HS_VM_DATA_SOURCE_NAME}" \
        "${P2P_HS_VM_DATA_SOURCE_NAMESPACE}" \
        "spoke"

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            typeset -i i
            for ((i = 1; i <= vmCount; i++)); do
                printf '=== Hub VM %d (%s-%d) — migration source for hub→spoke ===\n' \
                    "${i}" "${P2P_HS_HUB_VM_PREFIX}" "${i}"
                oc --kubeconfig="${KUBECONFIG}" get \
                    "virtualmachine/${P2P_HS_HUB_VM_PREFIX}-${i}" \
                    "virtualmachineinstance/${P2P_HS_HUB_VM_PREFIX}-${i}" \
                    -n "${P2P_HS_VM_NAMESPACE}" -o wide || true
                printf '=== Spoke VM %d (%s-%d) — migration source for spoke→hub ===\n' \
                    "${i}" "${P2P_HS_SPOKE_VM_PREFIX}" "${i}"
                oc --kubeconfig="${spokeKubeconfig}" get \
                    "virtualmachine/${P2P_HS_SPOKE_VM_PREFIX}-${i}" \
                    "virtualmachineinstance/${P2P_HS_SPOKE_VM_PREFIX}-${i}" \
                    -n "${P2P_HS_VM_NAMESPACE}" -o wide || true
            done
        } > "${ARTIFACT_DIR}/hub-spoke-vm-create-status.txt"
    fi
    true
) || cclmStepRc=$?

if (( cclmStepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-create-hub-spoke-test-vms failed (rc=${cclmStepRc}); not failing job (debug mode)"
    else
        exit "${cclmStepRc}"
    fi
fi

true
