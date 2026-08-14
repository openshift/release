#!/bin/bash
#
# Create a CNV test VM on the source spoke for MTV cross-cluster live migration (CCLM).
# Backed by ODF RWX block storage suitable for live migration.
#
# RHEL DataSource clones on ODF virt StorageClass require cloneStrategy=copy and
# cdi.kubevirt.io/storage.usePopulator=false to avoid prime-* ClaimMisbound failures.
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
typeset dvName="${CNV_TEST_VM_NAME}-rootdisk"
typeset diagDir=""

# SpokeOc — run oc against the source spoke cluster.
SpokeOc() {
    oc --kubeconfig="${spokeKubeconfig}" "$@"
}

# ResolveSpokeKubeconfig — source spoke admin kubeconfig from SHARED_DIR (written by cluster-install).
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

# DumpDiagnostics — write DV/PVC/events state to ARTIFACT_DIR on failure.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    diagDir="${ARTIFACT_DIR}/migration-test-vm-diagnostics"
    mkdir -p "${diagDir}"
    SpokeOc get "datavolume/${dvName}" "persistentvolumeclaim/${dvName}" \
        -n "${CNV_TEST_VM_NAMESPACE}" -o yaml > "${diagDir}/datavolume.yaml" 2>&1 || true
    SpokeOc get pvc -n "${CNV_TEST_VM_NAMESPACE}" -o wide > "${diagDir}/namespace-pvcs.txt" 2>&1 || true
    SpokeOc get events -n "${CNV_TEST_VM_NAMESPACE}" --sort-by='.lastTimestamp' \
        > "${diagDir}/namespace-events.txt" 2>&1 || true
    SpokeOc get storageprofile -o yaml > "${diagDir}/storageprofiles.yaml" 2>&1 || true
}

# OnError — dump diagnostics before propagating failure.
OnError() {
    typeset -i ec=$?
    DumpDiagnostics
    exit "${ec}"
}

# EnsureStorageProfileCloneStrategyCopy — ODF virt SC needs host-assisted copy for RHEL clones.
EnsureStorageProfileCloneStrategyCopy() {
    typeset spName profileCloneStrategy

    SpokeOc get "storageclass/${CNV_TEST_VM_STORAGE_CLASS}" 1>/dev/null
    SpokeOc annotate "storageclass/${CNV_TEST_VM_STORAGE_CLASS}" \
        cdi.kubevirt.io/clone-strategy=copy --overwrite 1>/dev/null

    spName="storageprofile.cdi.kubevirt.io/${CNV_TEST_VM_STORAGE_CLASS}"
    if ! SpokeOc get "${spName}" 1>/dev/null; then
        return 0
    fi

    profileCloneStrategy="$(SpokeOc get "${spName}" -o jsonpath='{.spec.cloneStrategy}' || true)"
    if [[ "${profileCloneStrategy}" != "copy" ]]; then
        SpokeOc patch "${spName}" --type merge -p '{"spec":{"cloneStrategy":"copy"}}'
    fi
}

# CleanupPriorResources — remove stale VM/DV/prime-* PVCs before recreate.
CleanupPriorResources() {
    typeset pvcName

    SpokeOc delete "virtualmachine/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" --ignore-not-found --wait=false
    SpokeOc delete "virtualmachineinstance/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" --ignore-not-found --wait=false
    SpokeOc delete "datavolume/${dvName}" -n "${CNV_TEST_VM_NAMESPACE}" --ignore-not-found --wait=false

    while read -r pvcName; do
        [[ -n "${pvcName}" ]] || continue
        SpokeOc delete "persistentvolumeclaim/${pvcName}" -n "${CNV_TEST_VM_NAMESPACE}" --ignore-not-found --wait=false
    done < <(SpokeOc get pvc -n "${CNV_TEST_VM_NAMESPACE}" -o json \
        | jq -r --arg dv "${dvName}" '.items[].metadata.name | select(test("^(" + $dv + "|prime-))"))' \
        || true)

    while read -r pvcName; do
        [[ -n "${pvcName}" ]] || continue
        SpokeOc patch "persistentvolumeclaim/${pvcName}" -n "${CNV_TEST_VM_NAMESPACE}" --type merge \
            -p '{"metadata":{"finalizers":null}}' 1>/dev/null || true
        SpokeOc delete "persistentvolumeclaim/${pvcName}" -n "${CNV_TEST_VM_NAMESPACE}" --ignore-not-found --wait=false
    done < <(SpokeOc get pvc -n "${CNV_TEST_VM_NAMESPACE}" -o json \
        | jq -r '.items[].metadata.name | select(startswith("prime-"))' \
        || true)

    SpokeOc wait --for=delete "datavolume/${dvName}" -n "${CNV_TEST_VM_NAMESPACE}" --timeout=5m 1>/dev/null || true
}

# ApplyCirrosDataVolume — HTTP import (no DataSource clone; fast and reliable).
ApplyCirrosDataVolume() {
    DV_NAME="${dvName}" yq e '
        .metadata.name                              = strenv(DV_NAME) |
        .metadata.namespace                         = strenv(CNV_TEST_VM_NAMESPACE) |
        .metadata.labels["app.kubernetes.io/name"]  = strenv(CNV_TEST_VM_NAME) |
        .spec.source.http.url                       = strenv(CNV_TEST_VM_CIRROS_IMAGE_URL) |
        .spec.storage.resources.requests.storage    = strenv(CNV_TEST_VM_DISK_SIZE) |
        .spec.storage.storageClassName               = strenv(CNV_TEST_VM_STORAGE_CLASS)
    ' - <<'YAML' | SpokeOc apply -f -
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
    SpokeOc get "datasource/${CNV_TEST_VM_DATA_SOURCE_NAME}" -n "${CNV_TEST_VM_DATA_SOURCE_NAMESPACE}" 1>/dev/null
    EnsureStorageProfileCloneStrategyCopy

    DV_NAME="${dvName}" yq e '
        .metadata.name                              = strenv(DV_NAME) |
        .metadata.namespace                         = strenv(CNV_TEST_VM_NAMESPACE) |
        .metadata.labels["app.kubernetes.io/name"]  = strenv(CNV_TEST_VM_NAME) |
        .spec.sourceRef.name                        = strenv(CNV_TEST_VM_DATA_SOURCE_NAME) |
        .spec.sourceRef.namespace                   = strenv(CNV_TEST_VM_DATA_SOURCE_NAMESPACE) |
        .spec.storage.resources.requests.storage    = strenv(CNV_TEST_VM_DISK_SIZE) |
        .spec.storage.storageClassName               = strenv(CNV_TEST_VM_STORAGE_CLASS)
    ' - <<'YAML' | SpokeOc apply -f -
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

# WaitDataVolumeReady — use CDI Ready condition (status.phase may be empty while PVC binds).
WaitDataVolumeReady() {
    SpokeOc wait "datavolume/${dvName}" -n "${CNV_TEST_VM_NAMESPACE}" \
        --for=condition=Ready --timeout="${CNV_TEST_VM_DATAVOLUME_WAIT_TIMEOUT}"
}

# ApplyCirrosVirtualMachine — minimal VM without cloud-init disk.
ApplyCirrosVirtualMachine() {
    DV_NAME="${dvName}" yq e '
        .metadata.name                                        = strenv(CNV_TEST_VM_NAME) |
        .metadata.namespace                                   = strenv(CNV_TEST_VM_NAMESPACE) |
        .metadata.labels["app.kubernetes.io/name"]            = strenv(CNV_TEST_VM_NAME) |
        .metadata.labels["vm.kubevirt.io/name"]               = strenv(CNV_TEST_VM_NAME) |
        .spec.template.metadata.labels["vm.kubevirt.io/name"] = strenv(CNV_TEST_VM_NAME) |
        .spec.template.spec.domain.cpu.cores                  = (strenv(CNV_TEST_VM_CPUS) | tonumber) |
        .spec.template.spec.domain.memory.guest               = strenv(CNV_TEST_VM_MEMORY) |
        .spec.template.spec.volumes[0].dataVolume.name        = strenv(DV_NAME)
    ' - <<'YAML' | SpokeOc apply -f -
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
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    # Build cloud-init userData without exposing password in xtrace.
    typeset _userData
    _userData="$(printf '#cloud-config\nuser: cloud-user\npassword: migration123\nchpasswd:\n  expire: false\nssh_pwauth: true\nruncmd:\n- echo "VM %s is ready for migration testing" > /tmp/vm-ready.txt\n' \
        "${CNV_TEST_VM_NAME}")"

    DV_NAME="${dvName}" \
    CLOUD_INIT_USERDATA="${_userData}" \
    yq e '
        .metadata.name                                        = strenv(CNV_TEST_VM_NAME) |
        .metadata.namespace                                   = strenv(CNV_TEST_VM_NAMESPACE) |
        .metadata.labels["app.kubernetes.io/name"]            = strenv(CNV_TEST_VM_NAME) |
        .metadata.labels["vm.kubevirt.io/name"]               = strenv(CNV_TEST_VM_NAME) |
        .spec.template.metadata.labels["vm.kubevirt.io/name"] = strenv(CNV_TEST_VM_NAME) |
        .spec.template.spec.domain.cpu.cores                  = (strenv(CNV_TEST_VM_CPUS) | tonumber) |
        .spec.template.spec.domain.memory.guest               = strenv(CNV_TEST_VM_MEMORY) |
        .spec.template.spec.volumes[0].dataVolume.name        = strenv(DV_NAME) |
        .spec.template.spec.volumes[1].cloudInitNoCloud.userData = strenv(CLOUD_INIT_USERDATA)
    ' - <<'YAML' | SpokeOc apply -f -
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

# WaitVmiRunning — wait for VMI object then Running phase.
WaitVmiRunning() {
    (
        SECONDS=0
        while (( SECONDS < 120 )); do
            SpokeOc get "virtualmachineinstance/${CNV_TEST_VM_NAME}" \
                -n "${CNV_TEST_VM_NAMESPACE}" 1>/dev/null && exit 0
            sleep 2
        done
        : "VMI ${CNV_TEST_VM_NAME} not found in ${CNV_TEST_VM_NAMESPACE} after 120s" >&2
        exit 1
    )

    SpokeOc wait "virtualmachineinstance/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Running --timeout="${CNV_TEST_VM_VMI_WAIT_TIMEOUT}"
}

trap - ERR

typeset -i cclmStepRc=0
(
    trap OnError ERR

    ResolveSpokeKubeconfig

    case "${CNV_TEST_VM_IMAGE_TYPE}" in
        cirros|rhel) ;;
        *) false ;;
    esac

    SpokeOc get crd virtualmachines.kubevirt.io 1>/dev/null
    SpokeOc get "storageclass/${CNV_TEST_VM_STORAGE_CLASS}" 1>/dev/null

    yq e '.metadata.name = strenv(CNV_TEST_VM_NAMESPACE)' - <<'YAML' | SpokeOc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: placeholder
  labels:
    app.kubernetes.io/part-of: vm-migration-test
YAML

    if [[ "${CNV_TEST_VM_CLEAN}" == "true" ]] \
        || SpokeOc get "datavolume/${dvName}" -n "${CNV_TEST_VM_NAMESPACE}" \
            -o jsonpath='{.status.phase}' | grep -qE 'Failed|Lost'; then
        CleanupPriorResources
    fi

    case "${CNV_TEST_VM_IMAGE_TYPE}" in
        cirros) ApplyCirrosDataVolume ;;
        rhel)   ApplyRhelDataVolume ;;
    esac

    WaitDataVolumeReady

    case "${CNV_TEST_VM_IMAGE_TYPE}" in
        cirros) ApplyCirrosVirtualMachine ;;
        rhel)   ApplyRhelVirtualMachine ;;
    esac

    WaitVmiRunning

    if [[ -n "${ARTIFACT_DIR}" ]]; then
        mkdir -p "${ARTIFACT_DIR}"
        {
            printf '%s\n' "vm_name=${CNV_TEST_VM_NAME}"
            printf '%s\n' "vm_namespace=${CNV_TEST_VM_NAMESPACE}"
            printf '%s\n' "image_type=${CNV_TEST_VM_IMAGE_TYPE}"
            printf '%s\n' "spoke_kubeconfig=${spokeKubeconfig}"
            SpokeOc get "virtualmachine/${CNV_TEST_VM_NAME}" "virtualmachineinstance/${CNV_TEST_VM_NAME}" \
                "datavolume/${dvName}" "persistentvolumeclaim/${dvName}" \
                -n "${CNV_TEST_VM_NAMESPACE}" -o wide
        } > "${ARTIFACT_DIR}/migration-test-vm-status.txt"
    fi
    true
) || cclmStepRc=$?

if (( cclmStepRc != 0 )); then
    DumpDiagnostics
    if [[ "${cclmDebugMode}" == "true" ]]; then
        : "WARNING: p2p-create-migration-test-vm failed (rc=${cclmStepRc}); not failing job (debug mode)"
    else
        exit "${cclmStepRc}"
    fi
fi

true
