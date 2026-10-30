#!/bin/bash
#
# Create Windows VMs for ACM+virt CCLM.
#
# DataImportCrons pull the Windows disk from Brew only after brew.registry.redhat.io
# is in the cluster pull secret. That update is done here, the same way
# openshift-cnv/cnv-ci hack/update-pull-secret.sh does it. It is not done by
# openshift-python-wrapper.
#
# xtrace stays off for this POC. set -x would record kubeconfig paths and any
# expanded proxy or registry credential on the traced command line.
set +x
set -Eeuo pipefail
shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    set +x
    # shellcheck disable=SC1090,SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

unset KUBERNETES_SERVICE_PORT_HTTPS KUBERNETES_SERVICE_PORT \
    KUBERNETES_PORT_443_TCP KUBERNETES_PORT_443_TCP_PROTO \
    KUBERNETES_PORT_443_TCP_ADDR KUBERNETES_SERVICE_HOST \
    KUBERNETES_PORT KUBERNETES_PORT_443_TCP_PORT

typeset -i vmCount="${P2P_HS_VM_COUNT}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE}"
typeset hcoKind="hyperconvergeds.v1beta1.hco.kubevirt.io"
typeset spokeKubeconfig=""
typeset brewSecretChanged=false
typeset brewAuthFile=""
typeset brewAuthFileNew=""
typeset diagDir=""

(( vmCount >= 1 ))
[[ -n "${KUBECONFIG}" && -r "${KUBECONFIG}" ]]

# ResolveSpokeKubeconfig picks the source spoke kubeconfig written by cluster install.
ResolveSpokeKubeconfig() {
    [[ -n "${SHARED_DIR}" ]]
    if [[ -n "${P2P_HS_SPOKE_KUBECONFIG}" ]]; then
        spokeKubeconfig="${P2P_HS_SPOKE_KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_HS_SPOKE_INDEX}" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_HS_SPOKE_INDEX}"
    elif [[ "${P2P_HS_SPOKE_INDEX}" == "1" && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
        printf 'ERROR: spoke kubeconfig not found for index %s\n' "${P2P_HS_SPOKE_INDEX}" >&2
        return 1
    fi
    [[ -r "${spokeKubeconfig}" ]]
}

# InjectBrewPullSecret merges brew.registry.redhat.io into the cluster pull secret.
# The token stays in its file. jq reads it with --rawfile so it is not a shell
# variable and not a process argument. Tracing is off for the whole update, and
# oc stdout is discarded because `oc set data` can print the Secret body.
InjectBrewPullSecret() {
    typeset kc="${1:?}"
    typeset -i rc=0
    # Keep tracing off while the cluster pull secret and Brew token are handled.
    set +x
    brewSecretChanged=false
    brewAuthFile="$(mktemp)"
    brewAuthFileNew="$(mktemp)"
    chmod 600 "${brewAuthFile}" "${brewAuthFileNew}"
    if [[ ! -s "${BREW_IMAGE_REGISTRY_TOKEN_PATH}" ]]; then
        printf 'ERROR: Brew registry token file is missing or empty\n' >&2
        rc=1
    elif ! oc --kubeconfig="${kc}" get secret/pull-secret -n openshift-config \
        -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${brewAuthFile}"; then
        printf 'ERROR: failed to read openshift-config/pull-secret\n' >&2
        rc=1
    elif jq -e '.auths["brew.registry.redhat.io"].auth // "" | length > 0' \
        "${brewAuthFile}" >/dev/null; then
        printf 'INFO: brew.registry.redhat.io is already in the cluster pull secret\n' >&2
    elif ! jq -e --arg user "${BREW_IMAGE_REGISTRY_USERNAME}" \
        --rawfile token "${BREW_IMAGE_REGISTRY_TOKEN_PATH}" '
            ($token | gsub("\r"; "") | gsub("\n"; "")) as $t
            | if (($user | length) == 0) or (($t | length) == 0) then
                error("empty brew credential")
              else . end
            | .auths["brew.registry.redhat.io"] = {auth: (($user + ":" + $t) | @base64)}
        ' "${brewAuthFile}" > "${brewAuthFileNew}"; then
        printf 'ERROR: failed to merge Brew registry auth into the pull secret\n' >&2
        rc=1
    elif ! oc --kubeconfig="${kc}" set data secret/pull-secret -n openshift-config \
        --from-file=.dockerconfigjson="${brewAuthFileNew}" >/dev/null; then
        printf 'ERROR: failed to update openshift-config/pull-secret\n' >&2
        rc=1
    else
        brewSecretChanged=true
        printf 'INFO: added brew.registry.redhat.io to the cluster pull secret\n' >&2
    fi
    rm -f "${brewAuthFile}" "${brewAuthFileNew}"
    brewAuthFile=""
    brewAuthFileNew=""
    return "${rc}"
}

# WaitMcpSettled waits until a pull-secret roll has started and then finished.
WaitMcpSettled() {
    typeset kc="${1:?}"
    typeset -i timeoutSec
    typeset -i start=${SECONDS}
    typeset -i sawUpdating=0
    typeset mcpFile=""
    timeoutSec="$(TimeoutToSeconds "${CCLM_MCP_WAIT_TIMEOUT}")"
    mcpFile="$(mktemp)"
    printf 'INFO: waiting for MachineConfigPools to roll the updated pull secret\n' >&2
    while (( SECONDS - start < timeoutSec )); do
        oc --kubeconfig="${kc}" get mcp -o json > "${mcpFile}"
        if jq -e '[.items[].status.conditions[]? | select(.type=="Updating" and .status=="True")] | length > 0' \
            "${mcpFile}" >/dev/null; then
            sawUpdating=1
        fi
        if jq -e '
            [.items[] | select(
                ([.status.conditions[]? | select(.type=="Updated" and .status=="True")] | length) == 0
                or ([.status.conditions[]? | select(.type=="Updating" and .status=="True")] | length) > 0
            )] | length == 0
        ' "${mcpFile}" >/dev/null \
            && { (( sawUpdating == 1 )) || (( SECONDS - start > 180 )); }; then
            rm -f "${mcpFile}"
            printf 'INFO: MachineConfigPools are updated\n' >&2
            return 0
        fi
        sleep 20
    done
    rm -f "${mcpFile}"
    printf 'ERROR: MachineConfigPools did not settle after the pull-secret update\n' >&2
    oc --kubeconfig="${kc}" get mcp >&2
    return 1
}

# TimeoutToSeconds converts a CI duration (45m, 90s, 1h) to seconds.
TimeoutToSeconds() {
    typeset raw="${1:?}"
    typeset -i value
    case "${raw}" in
        *h) value="${raw%h}"; printf '%s' "$((value * 3600))" ;;
        *m) value="${raw%m}"; printf '%s' "$((value * 60))" ;;
        *s) printf '%s' "${raw%s}" ;;
        *) printf '%s' "${raw}" ;;
    esac
}

# SetVirtDefaultStorageClass makes the ODF virt StorageClass the default import target.
SetVirtDefaultStorageClass() {
    typeset kc="${1:?}"
    typeset sc="${2:?}"
    typeset name=""
    oc --kubeconfig="${kc}" get "storageclass/${sc}" >/dev/null
    while read -r name; do
        [[ -n "${name}" ]] || continue
        oc --kubeconfig="${kc}" patch "${name}" --type merge -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false","storageclass.kubevirt.io/is-default-virt-class":"false"}}}'
    done < <(oc --kubeconfig="${kc}" get storageclass -o name)
    oc --kubeconfig="${kc}" patch "storageclass/${sc}" --type merge -p \
        '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true","storageclass.kubevirt.io/is-default-virt-class":"true"}}}'
}

# EnsureStorageProfileCloneStrategyCopy forces host-assisted copy for ODF clones.
EnsureStorageProfileCloneStrategyCopy() {
    typeset kc="${1:?}"
    typeset sc="${2:?}"
    typeset spName="storageprofile.cdi.kubevirt.io/${sc}"
    typeset profileCloneStrategy=""
    oc --kubeconfig="${kc}" annotate "storageclass/${sc}" \
        cdi.kubevirt.io/clone-strategy=copy --overwrite >/dev/null
    if ! oc --kubeconfig="${kc}" get "${spName}" >/dev/null; then
        return 0
    fi
    profileCloneStrategy="$(oc --kubeconfig="${kc}" get "${spName}" -o jsonpath='{.spec.cloneStrategy}')"
    if [[ "${profileCloneStrategy}" != "copy" ]]; then
        oc --kubeconfig="${kc}" patch "${spName}" --type merge -p '{"spec":{"cloneStrategy":"copy"}}'
    fi
}

# EnsureWindowsDataSource waits until HCO has a Ready Windows boot image.
EnsureWindowsDataSource() {
    typeset kc="${1:?}"
    typeset -i timeoutSec
    typeset -i start=${SECONDS}
    typeset cronName=""
    timeoutSec="$(TimeoutToSeconds "${CCLM_WINDOWS_DATASOURCE_WAIT_TIMEOUT}")"
    oc --kubeconfig="${kc}" scale deployment hco-operator --replicas=1 -n openshift-cnv
    oc --kubeconfig="${kc}" patch "${hcoKind}" kubevirt-hyperconverged -n openshift-cnv \
        --type merge \
        -p '{"spec":{"featureGates":{"enableCommonBootImageImport":true}}}'
    oc --kubeconfig="${kc}" wait "${hcoKind}" kubevirt-hyperconverged -n openshift-cnv \
        --for=condition=Available --timeout=5m

    if WindowsDataSourceReady "${kc}"; then
        printf 'INFO: DataSource %s is already Ready\n' "${CCLM_WINDOWS_DATASOURCE}" >&2
        return 0
    fi

    printf 'INFO: recycling Windows DataImportCrons so they pull with Brew credentials\n' >&2
    typeset dsLower="${CCLM_WINDOWS_DATASOURCE,,}"
    typeset lower=""
    while read -r cronName; do
        [[ -n "${cronName}" ]] || continue
        lower="${cronName,,}"
        [[ "${lower}" == *"${dsLower}"* ]] || continue
        oc --kubeconfig="${kc}" delete "dataimportcron/${cronName}" \
            -n "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" --wait=false
    done < <(oc --kubeconfig="${kc}" get dataimportcron -n "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    oc --kubeconfig="${kc}" delete "datasource/${CCLM_WINDOWS_DATASOURCE}" \
        -n "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" --ignore-not-found --wait=false
    oc --kubeconfig="${kc}" annotate "${hcoKind}" kubevirt-hyperconverged -n openshift-cnv \
        cclm.openshift.io/windows-reimport="$(date +%s)" --overwrite >/dev/null

    while (( SECONDS - start < timeoutSec )); do
        if WindowsDataSourceReady "${kc}"; then
            printf 'INFO: DataSource %s is Ready\n' "${CCLM_WINDOWS_DATASOURCE}" >&2
            return 0
        fi
        sleep 20
    done
    printf 'ERROR: DataSource %s/%s did not become Ready\n' \
        "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" "${CCLM_WINDOWS_DATASOURCE}" >&2
    oc --kubeconfig="${kc}" get dataimportcron,datasource,pvc \
        -n "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" -o name >&2
    return 1
}

# WindowsDataSourceReady reports whether the configured DataSource condition is True.
WindowsDataSourceReady() {
    typeset kc="${1:?}"
    typeset ready=""
    ready="$(oc --kubeconfig="${kc}" get "datasource/${CCLM_WINDOWS_DATASOURCE}" \
        -n "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" || return 1
    [[ "${ready}" == "True" ]]
}

# EnsureNamespace creates the migration namespace when it is missing.
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

# CleanupVm removes a previous VM and its root disk so a rerun can recreate them.
CleanupVm() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"
    typeset dvName="${vmName}-rootdisk"
    oc --kubeconfig="${kc}" delete "virtualmachine/${vmName}" -n "${ns}" --ignore-not-found --wait=false
    oc --kubeconfig="${kc}" delete "virtualmachineinstance/${vmName}" -n "${ns}" --ignore-not-found --wait=false
    if oc --kubeconfig="${kc}" get "datavolume/${dvName}" -n "${ns}" >/dev/null; then
        oc --kubeconfig="${kc}" delete "datavolume/${dvName}" -n "${ns}" --wait=false
        oc --kubeconfig="${kc}" wait --for=delete "datavolume/${dvName}" -n "${ns}" --timeout=5m
    fi
}

# ApplyWindowsDataVolume clones the Windows DataSource onto ODF RWX block storage.
ApplyWindowsDataVolume() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"
    typeset sc="${4:?}"
    typeset dvName="${vmName}-rootdisk"
    vmName="${vmName}" DV_NAME="${dvName}" VM_NS="${ns}" VM_SC="${sc}" \
        DS_NAME="${CCLM_WINDOWS_DATASOURCE}" DS_NS="${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" \
        yq e '
            .metadata.name = strenv(DV_NAME) |
            .metadata.namespace = strenv(VM_NS) |
            .metadata.labels["app.kubernetes.io/name"] = strenv(vmName) |
            .spec.sourceRef.name = strenv(DS_NAME) |
            .spec.sourceRef.namespace = strenv(DS_NS) |
            .spec.storage.resources.requests.storage = strenv(P2P_HS_VM_DISK_SIZE) |
            .spec.storage.storageClassName = strenv(VM_SC)
        ' - <<'YAML' | oc --kubeconfig="${kc}" apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: placeholder
  namespace: placeholder
  labels:
    app.kubernetes.io/name: placeholder
    vm.kubevirt.io/image: windows
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

# ApplyWindowsVirtualMachine creates a live-migratable Windows VM from its DataVolume.
ApplyWindowsVirtualMachine() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"
    typeset dvName="${vmName}-rootdisk"
    vmName="${vmName}" DV_NAME="${dvName}" VM_NS="${ns}" \
        yq e '
            .metadata.name = strenv(vmName) |
            .metadata.namespace = strenv(VM_NS) |
            .metadata.labels["app.kubernetes.io/name"] = strenv(vmName) |
            .metadata.labels["vm.kubevirt.io/name"] = strenv(vmName) |
            .spec.template.metadata.labels["vm.kubevirt.io/name"] = strenv(vmName) |
            .spec.template.spec.domain.cpu.cores = (strenv(P2P_HS_VM_CPUS) | tonumber) |
            .spec.template.spec.domain.memory.guest = strenv(P2P_HS_VM_MEMORY) |
            .spec.template.spec.domain.devices.disks[0].disk.bus = strenv(CCLM_WINDOWS_DISK_BUS) |
            .spec.template.spec.domain.machine.type = strenv(CCLM_WINDOWS_MACHINE_TYPE) |
            .spec.template.spec.volumes[0].dataVolume.name = strenv(DV_NAME)
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
              bus: sata
          interfaces:
          - name: default
            masquerade: {}
        features:
          acpi: {}
        machine:
          type: q35
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
    oc --kubeconfig="${kc}" get "virtualmachine/${vmName}" -n "${ns}" >/dev/null
}

# WaitVmiRunning waits until the guest VMI exists and is Running.
WaitVmiRunning() {
    typeset kc="${1:?}"
    typeset vmName="${2:?}"
    typeset ns="${3:?}"
    typeset -i start=${SECONDS}
    while (( SECONDS - start < 180 )); do
        if oc --kubeconfig="${kc}" get "virtualmachineinstance/${vmName}" -n "${ns}" >/dev/null; then
            break
        fi
        sleep 5
    done
    oc --kubeconfig="${kc}" get "virtualmachineinstance/${vmName}" -n "${ns}" >/dev/null
    oc --kubeconfig="${kc}" wait "virtualmachineinstance/${vmName}" -n "${ns}" \
        --for=jsonpath='{.status.phase}'=Running \
        --timeout="${P2P_HS_VM_VMI_WAIT_TIMEOUT}"
}

# CreateClusterVms imports Windows disks and starts one VM per index.
CreateClusterVms() {
    typeset kc="${1:?}"
    typeset vmPrefix="${2:?}"
    typeset ns="${3:?}"
    typeset sc="${4:?}"
    typeset clusterLabel="${5:?}"
    typeset -i i
    typeset vmName="" dvName=""

    oc --kubeconfig="${kc}" get crd virtualmachines.kubevirt.io >/dev/null
    InjectBrewPullSecret "${kc}"
    if [[ "${brewSecretChanged}" == "true" ]]; then
        WaitMcpSettled "${kc}"
    fi
    SetVirtDefaultStorageClass "${kc}" "${sc}"
    EnsureWindowsDataSource "${kc}"
    EnsureStorageProfileCloneStrategyCopy "${kc}" "${sc}"
    EnsureNamespace "${kc}" "${ns}"

    for ((i = 1; i <= vmCount; i++)); do
        vmName="${vmPrefix}-${i}"
        dvName="${vmName}-rootdisk"
        if [[ "${P2P_HS_VM_CLEAN}" == "true" ]]; then
            CleanupVm "${kc}" "${vmName}" "${ns}"
        fi
        printf 'INFO: creating %s DataVolume %s\n' "${clusterLabel}" "${dvName}" >&2
        ApplyWindowsDataVolume "${kc}" "${vmName}" "${ns}" "${sc}"
    done
    for ((i = 1; i <= vmCount; i++)); do
        vmName="${vmPrefix}-${i}"
        dvName="${vmName}-rootdisk"
        oc --kubeconfig="${kc}" wait "datavolume/${dvName}" -n "${ns}" \
            --for=condition=Ready --timeout="${P2P_HS_VM_DATAVOLUME_WAIT_TIMEOUT}"
    done
    for ((i = 1; i <= vmCount; i++)); do
        vmName="${vmPrefix}-${i}"
        printf 'INFO: starting %s Windows VM %s\n' "${clusterLabel}" "${vmName}" >&2
        ApplyWindowsVirtualMachine "${kc}" "${vmName}" "${ns}"
        WaitVmiRunning "${kc}" "${vmName}" "${ns}"
    done
}

# DumpDiagnostics writes VM and boot-image state for a failed run.
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR:-}" ]] || return 0
    diagDir="${ARTIFACT_DIR}/windows-vm-create-diagnostics"
    mkdir -p "${diagDir}"
    typeset -i i
    typeset vmName=""
    if [[ -n "${spokeKubeconfig}" ]]; then
        oc --kubeconfig="${spokeKubeconfig}" get dataimportcron,datasource,pvc \
            -n "${CCLM_WINDOWS_DATASOURCE_NAMESPACE}" -o yaml \
            > "${diagDir}/spoke-boot-images.yaml" || true
        for ((i = 1; i <= vmCount; i++)); do
            vmName="${P2P_HS_SPOKE_VM_PREFIX}-${i}"
            oc --kubeconfig="${spokeKubeconfig}" get "virtualmachine/${vmName}" \
                -n "${P2P_HS_VM_NAMESPACE}" -o yaml \
                > "${diagDir}/spoke-${vmName}.yaml" || true
            oc --kubeconfig="${spokeKubeconfig}" get "datavolume/${vmName}-rootdisk" \
                -n "${P2P_HS_VM_NAMESPACE}" -o yaml \
                > "${diagDir}/spoke-${vmName}-dv.yaml" || true
        done
    fi
}

ScrubBrewAuthFiles() {
    if [[ -n "${brewAuthFile}" ]]; then
        rm -f "${brewAuthFile}"
    fi
    if [[ -n "${brewAuthFileNew}" ]]; then
        rm -f "${brewAuthFileNew}"
    fi
    brewAuthFile=""
    brewAuthFileNew=""
    return 0
}

OnError() {
    typeset -i ec=$?
    ScrubBrewAuthFiles
    DumpDiagnostics || true
    if [[ "${cclmDebugMode}" == "true" ]]; then
        printf 'WARNING: p2p-cclm-create-windows-vm failed (rc=%s); debug mode keeps the job going\n' "${ec}" >&2
        exit 0
    fi
    exit "${ec}"
}
trap OnError ERR
trap ScrubBrewAuthFiles EXIT

ResolveSpokeKubeconfig
CreateClusterVms "${spokeKubeconfig}" "${P2P_HS_SPOKE_VM_PREFIX}" \
    "${P2P_HS_VM_NAMESPACE}" "${P2P_HS_SPOKE_STORAGE_CLASS}" "spoke"
if [[ "${P2P_HS_CREATE_HUB_VMS}" == "true" ]]; then
    CreateClusterVms "${KUBECONFIG}" "${P2P_HS_HUB_VM_PREFIX}" \
        "${P2P_HS_VM_NAMESPACE}" "${P2P_HS_HUB_STORAGE_CLASS}" "hub"
fi

printf 'INFO: Windows VMs are running\n' >&2
