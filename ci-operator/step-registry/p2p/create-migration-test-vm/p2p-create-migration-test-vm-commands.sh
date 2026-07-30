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

# WaitForVirtApiReady — wait for virt-api AND cdi-apiserver Deployments to be ready.
#
# TWO separate webhook servers handle CNV resource creation:
#   - virt-api (openshift-cnv): VirtualMachine, VMI, VMIM mutators
#   - cdi-apiserver (openshift-cnv): DataVolume, DataSource mutators
#
# `rollout status` checks pod readiness, NOT webhook endpoint responsiveness.
# After the rollout completes the actual TLS/cert-manager webhook endpoint may
# still take several seconds to start accepting requests. CNV_VIRT_API_SETTLE_SECS
# (default 15) adds a short extra wait after rollout to reduce webhook timeout races.
WaitForVirtApiReady() {
    typeset cnvNs="${CNV_VIRT_API_NAMESPACE:-openshift-cnv}"
    typeset timeout="${CNV_VIRT_API_WAIT_TIMEOUT:-5m}"
    typeset -i settleSecs="${CNV_VIRT_API_SETTLE_SECS:-15}"

    : "Waiting for virt-api in '${cnvNs}' (timeout=${timeout})"
    SpokeOc rollout status deployment/virt-api -n "${cnvNs}" --timeout="${timeout}" 1>/dev/null

    # DataVolume webhooks are served by cdi-apiserver, NOT virt-api.
    # Wait for cdi-apiserver separately; ignore if the deployment doesn't exist
    # (some CNV builds ship a different name).
    if SpokeOc get deployment/cdi-apiserver -n "${cnvNs}" 1>/dev/null 2>&1; then
        : "Waiting for cdi-apiserver in '${cnvNs}' (timeout=${timeout})"
        SpokeOc rollout status deployment/cdi-apiserver -n "${cnvNs}" \
            --timeout="${timeout}" 1>/dev/null
    fi

    # Extra settle time: pod readiness probes pass before the webhook endpoint
    # is fully initialised. A short sleep avoids InternalError on the first apply.
    if (( settleSecs > 0 )); then
        : "Waiting ${settleSecs}s for CNV webhook endpoints to settle after rollout"
        sleep "${settleSecs}"
    fi
}

# SpokeApplyWithRetry — drain stdin to a temp file then retry SpokeOc apply up to
# CNV_APPLY_MAX_RETRIES (default 5) times. Between attempts, call WaitForVirtApiReady
# to wait for both virt-api and cdi-apiserver, then sleep CNV_APPLY_RETRY_SLEEP_SECS
# (default 30) for the webhook endpoints to settle.
# WHY temp file: stdin from a pipe can only be read once; the retry loop needs to
# replay the same manifest bytes on each attempt.
SpokeApplyWithRetry() {
    typeset -i maxRetries="${CNV_APPLY_MAX_RETRIES:-5}"
    typeset -i retrySleepSecs="${CNV_APPLY_RETRY_SLEEP_SECS:-30}"
    typeset tmpManifest
    tmpManifest="$(mktemp /tmp/manifest-XXXXXX.yaml)"
    cat > "${tmpManifest}"

    typeset -i attempt=0
    typeset -i applyRc=0
    while (( attempt < maxRetries )); do
        (( attempt++ ))
        applyRc=0
        SpokeOc apply -f "${tmpManifest}" || applyRc=$?
        if (( applyRc == 0 )); then
            rm -f "${tmpManifest}"
            return 0
        fi
        if (( attempt < maxRetries )); then
            : "SpokeApplyWithRetry: attempt ${attempt}/${maxRetries} failed (rc=${applyRc}) — waiting for CNV webhooks before retry"
            WaitForVirtApiReady || true
            sleep "${retrySleepSecs}"
        fi
    done

    rm -f "${tmpManifest}"
    : "SpokeApplyWithRetry: all ${maxRetries} attempts failed (last rc=${applyRc})" >&2
    return "${applyRc}"
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
    ' - <<'YAML' | SpokeApplyWithRetry
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
    ' - <<'YAML' | SpokeApplyWithRetry
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
    ' - <<'YAML' | SpokeApplyWithRetry
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
    ' - <<'YAML' | SpokeApplyWithRetry
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
# Uses a flag-based loop instead of an inner-subshell exit so that failures
# propagate correctly through `set -e` / `inherit_errexit` even when the
# function is called inside a `( ... ) || rc=$?` compound command.
WaitVmiRunning() {
    typeset -i _vmiFound=0
    SECONDS=0
    while (( SECONDS < 120 )); do
        if SpokeOc get "virtualmachineinstance/${CNV_TEST_VM_NAME}" \
                -n "${CNV_TEST_VM_NAMESPACE}" 1>/dev/null 2>/dev/null; then
            _vmiFound=1
            break
        fi
        sleep 2
    done

    if (( !_vmiFound )); then
        : "VMI ${CNV_TEST_VM_NAME} not found in ${CNV_TEST_VM_NAMESPACE} after 120s" >&2
        return 1
    fi

    SpokeOc wait "virtualmachineinstance/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Running --timeout="${CNV_TEST_VM_VMI_WAIT_TIMEOUT}"
}

trap - ERR

typeset -i cclmStepRc=0
(
    # bash set -e is suppressed for all commands inside ( ... ) || cclmStepRc=$?
    # (the left side of || runs in an "errexit-ignored" context per POSIX/bash).
    # Functions returning non-zero do NOT abort the subshell automatically. Use
    # explicit || _vmFailed=1 on every critical call and make (( _vmFailed == 0 ))
    # the LAST command so the subshell exit code reflects any failure.
    typeset -i _vmFailed=0

    trap OnError ERR

    ResolveSpokeKubeconfig || _vmFailed=1

    case "${CNV_TEST_VM_IMAGE_TYPE}" in
        cirros|rhel) ;;
        *) _vmFailed=1 ;;
    esac

    SpokeOc get crd virtualmachines.kubevirt.io 1>/dev/null || _vmFailed=1
    SpokeOc get "storageclass/${CNV_TEST_VM_STORAGE_CLASS}" 1>/dev/null || _vmFailed=1

    yq e '.metadata.name = strenv(CNV_TEST_VM_NAMESPACE)' - <<'YAML' | SpokeOc apply -f - || _vmFailed=1
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
        CleanupPriorResources || _vmFailed=1
    fi

    # Ensure virt-api is fully ready before creating CNV resources.  All CNV
    # admission webhooks (DataVolume, VirtualMachine mutators) are served by
    # virt-api pods; an overloaded or restarting virt-api causes webhook timeouts
    # that make `oc apply` fail with InternalError. SpokeApplyWithRetry will
    # additionally retry and re-check readiness on each webhook error.
    WaitForVirtApiReady || _vmFailed=1

    case "${CNV_TEST_VM_IMAGE_TYPE}" in
        cirros) ApplyCirrosDataVolume || _vmFailed=1 ;;
        rhel)   ApplyRhelDataVolume   || _vmFailed=1 ;;
    esac
    # Verify the DataVolume object was actually created.  Some CNV admission
    # webhooks use failurePolicy:Ignore and return exit 0 from `oc apply`
    # even when mutation failed, so the object may not exist after apply.
    SpokeOc get "datavolume/${dvName}" -n "${CNV_TEST_VM_NAMESPACE}" 1>/dev/null \
        || _vmFailed=1

    WaitDataVolumeReady || _vmFailed=1

    case "${CNV_TEST_VM_IMAGE_TYPE}" in
        cirros) ApplyCirrosVirtualMachine || _vmFailed=1 ;;
        rhel)   ApplyRhelVirtualMachine   || _vmFailed=1 ;;
    esac
    # Verify the VirtualMachine object was actually created (same webhook risk).
    SpokeOc get "virtualmachine/${CNV_TEST_VM_NAME}" -n "${CNV_TEST_VM_NAMESPACE}" 1>/dev/null \
        || _vmFailed=1

    WaitVmiRunning || _vmFailed=1

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
        } > "${ARTIFACT_DIR}/migration-test-vm-status.txt" || true
    fi
    # LAST command: propagate any critical failure as the subshell exit code.
    # No trailing `true` — the old trailing `true` silently overrode all failures
    # above (set -e is suppressed inside ( ) || rc=$? left-hand-side).
    (( _vmFailed == 0 ))
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
