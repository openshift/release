#!/bin/bash
#
# Import a Windows qcow2 from S3 onto an ACM spoke and start it for CCLM.
# The guest is created on the spoke kubeconfig, on the ODF RWX block
# StorageClass the spoke-to-spoke MTV plan migrates. CNV and ODF must
# already be installed on that spoke.
#
set -euxo pipefail; shopt -s inherit_errexit

# Source the CI proxy before any outbound call. This step does not download
# or eval a remote helper; jq is not required.
if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # Disable tracing: proxy-conf.sh may set HTTP_PROXY with embedded credentials.
    typeset _wasTracing=''
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
    if [[ "${_wasTracing}" == "true" ]]; then
        set -x
    fi
fi

[[ -n "${SHARED_DIR}" && -d "${SHARED_DIR}" ]]

if [[ -z "${WINDOWS_IMAGE_URL:-}" ]]; then
    printf 'ERROR: WINDOWS_IMAGE_URL is empty\n' >&2
    exit 1
fi
case "${WINDOWS_IMAGE_URL}" in
    https://*/dist/*) ;;
    *)
        printf 'ERROR: WINDOWS_IMAGE_URL must be an HTTPS URL pointing at the dist/ subdirectory\n' >&2
        exit 1
        ;;
esac
if [[ "${WINDOWS_IMAGE_URL}" == *[[:space:]]* || "${WINDOWS_IMAGE_URL}" == *\"* || "${WINDOWS_IMAGE_URL}" == *\'* ]]; then
    printf 'ERROR: WINDOWS_IMAGE_URL contains unsupported characters\n' >&2
    exit 1
fi

# Trusted digest of the qcow2. CDI checks it while importing, before the VM starts.
# Do not invent a value here; the job must supply the publisher's SHA-256.
typeset imageSha="${WINDOWS_IMAGE_SHA256:-}"
imageSha="${imageSha#sha256:}"
if [[ -z "${imageSha}" ]]; then
    printf 'ERROR: WINDOWS_IMAGE_SHA256 is empty; set the trusted SHA-256 of the qcow2\n' >&2
    exit 1
fi
if [[ ! "${imageSha}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf 'ERROR: WINDOWS_IMAGE_SHA256 must be a 64-character SHA-256 hex digest\n' >&2
    exit 1
fi
typeset imageChecksum="sha256:${imageSha}"

# Names are interpolated into manifests. Reject anything that is not a token.
function RejectUnsafe () {
    typeset name="${1:?}"
    typeset value="${2-}"
    [[ -n "${value}" && "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
        printf 'ERROR: %s is empty or contains unsupported characters\n' "${name}" >&2
        exit 1
    }
}
RejectUnsafe VM_NAME "${VM_NAME}"
RejectUnsafe VM_NAMESPACE "${VM_NAMESPACE}"
RejectUnsafe STORAGE_CLASS "${STORAGE_CLASS}"
RejectUnsafe VM_DISK_SIZE "${VM_DISK_SIZE}"
RejectUnsafe VM_MEMORY "${VM_MEMORY}"

typeset credDir=''
typeset spokeKubeconfig=''
typeset secretName="${VM_NAME}-s3"
typeset dvName="${VM_NAME}-rootdisk"
typeset diagDumped=false
typeset inTrap=false
typeset -r s3KeyIdSrc='/var/run/secrets/windows-vm/AWS__S3__u-ieng--s3--vm-img--windows--ro__AccKeyId'
typeset -r s3KeySecretSrc='/var/run/secrets/windows-vm/AWS__S3__u-ieng--s3--vm-img--windows--ro__AccKeySecret'

# ResolveSpokeKubeconfig picks the spoke admin kubeconfig written by
# acm-interop-p2p-cluster-install. The hub KUBECONFIG is not the target.
function ResolveSpokeKubeconfig () {
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

# SpokeOc runs oc against the source spoke.
function SpokeOc () {
    oc --kubeconfig="${spokeKubeconfig}" "$@"
}

# CleanupCreds removes the temporary copies of the S3 IAM keys.
function CleanupCreds () {
    if [[ -n "${credDir}" && -d "${credDir}" ]]; then
        rm -rf "${credDir}"
        credDir=''
    fi
}

# DumpDiagnostics writes DV/PVC/VM state from the spoke. Best-effort.
function DumpDiagnostics () {
    [[ "${diagDumped}" == "true" ]] && return 0
    diagDumped=true
    [[ -n "${ARTIFACT_DIR:-}" ]] || return 0
    [[ -n "${spokeKubeconfig}" && -r "${spokeKubeconfig}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/s3-windows-vm"
    mkdir -p "${diagDir}"
    SpokeOc get datavolume,pvc,vm,vmi -n "${VM_NAMESPACE}" -o yaml \
        > "${diagDir}/resources.yaml" 2>&1 || true
    SpokeOc describe datavolume -n "${VM_NAMESPACE}" \
        > "${diagDir}/datavolume-describe.txt" 2>&1 || true
}

# OnError dumps diagnostics, then exits with the original status.
# EXIT removes the credential temp dir.
function OnError () {
    typeset -i ec=$?
    if [[ "${inTrap}" == "true" ]]; then
        exit "${ec}"
    fi
    inTrap=true
    set +x
    DumpDiagnostics
    exit "${ec}"
}

function OnExit () {
    typeset -i ec=$?
    set +x
    CleanupCreds
    exit "${ec}"
}

ResolveSpokeKubeconfig
printf 'Creating Windows VM %s on spoke index %s\n' "${VM_NAME}" "${P2P_HS_SPOKE_INDEX}" >&2

trap OnError ERR
trap OnExit EXIT

# EnsureNamespace creates the CCLM VM namespace on the spoke when it is missing.
function EnsureNamespace () {
    SpokeOc create namespace "${VM_NAMESPACE}" --dry-run=client -o yaml | SpokeOc apply -f -
    SpokeOc wait "namespace/${VM_NAMESPACE}" --for=jsonpath='{.status.phase}'=Active --timeout=60s 1>/dev/null
}

# CreateS3Secret copies the mounted IAM keys into a secret CDI on the spoke can read.
# Tracing is off for the whole copy so key material cannot land in the log.
function CreateS3Secret () {
    typeset -i rc=0
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    # Disable tracing while copying S3 IAM keys into the spoke secret.
    {
        [[ -r "${s3KeyIdSrc}" ]]
        [[ -r "${s3KeySecretSrc}" ]]
        credDir="$(mktemp -d)"
        chmod 700 "${credDir}"
        cp -- "${s3KeyIdSrc}" "${credDir}/accessKeyId"
        cp -- "${s3KeySecretSrc}" "${credDir}/secretKey"
        chmod 600 "${credDir}/accessKeyId" "${credDir}/secretKey"
        [[ -s "${credDir}/accessKeyId" ]]
        [[ -s "${credDir}/secretKey" ]]
        SpokeOc create secret generic "${secretName}" \
            -n "${VM_NAMESPACE}" \
            --from-file="accessKeyId=${credDir}/accessKeyId" \
            --from-file="secretKey=${credDir}/secretKey" \
            --dry-run=client -o yaml | SpokeOc apply -f -
    } || rc=$?
    if [[ "${_wasTracing}" == "true" ]]; then
        set -x
    fi
    return "${rc}"
}

# ApplyDataVolume creates the CDI S3 import on the ODF virt StorageClass.
# RWX block is what the CCLM StorageMap migrates. usePopulator=false avoids
# the prime-* ClaimMisbound failure the other CCLM DataVolumes hit on ODF.
# storage.import.checksum is copied onto the PVC; the importer rejects the
# volume when the downloaded bytes do not match, so the VM is not started.
function ApplyDataVolume () {
    SpokeOc get "storageclass/${STORAGE_CLASS}" 1>/dev/null
    SpokeOc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${dvName}
  namespace: ${VM_NAMESPACE}
  annotations:
    cdi.kubevirt.io/storage.usePopulator: "false"
    cdi.kubevirt.io/storage.import.checksum: "${imageChecksum}"
spec:
  source:
    s3:
      url: "${WINDOWS_IMAGE_URL}"
      secretRef: "${secretName}"
  storage:
    storageClassName: ${STORAGE_CLASS}
    accessModes:
    - ReadWriteMany
    volumeMode: Block
    resources:
      requests:
        storage: ${VM_DISK_SIZE}
EOF
    SpokeOc get "datavolume/${dvName}" -n "${VM_NAMESPACE}" 1>/dev/null
}

# ApplyVirtualMachine starts the Windows guest. runStrategy Always is what the
# CCLM verify step requires after migration. EFI secure boot is off because
# the imported qcow2 is not signed for the KubeVirt default. SATA is used
# because the Windows template does not ship virtio drivers. The disk is a
# dataVolume so MTV resolves the same root disk the RHEL CCLM VMs use.
function ApplyVirtualMachine () {
    if [[ ! "${VM_CPU_CORES}" =~ ^[0-9]+$ ]]; then
        printf 'ERROR: VM_CPU_CORES must be an integer\n' >&2
        exit 1
    fi
    SpokeOc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${VM_NAMESPACE}
  labels:
    vm.kubevirt.io/name: ${VM_NAME}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
        vm.kubevirt.io/name: ${VM_NAME}
    spec:
      evictionStrategy: LiveMigrate
      terminationGracePeriodSeconds: 180
      domain:
        cpu:
          cores: ${VM_CPU_CORES}
        memory:
          guest: ${VM_MEMORY}
        machine:
          type: q35
        firmware:
          bootloader:
            efi:
              secureBoot: false
        devices:
          disks:
          - name: rootdisk
            bootOrder: 1
            disk:
              bus: sata
          interfaces:
          - name: default
            masquerade: {}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: ${dvName}
EOF
    SpokeOc get "virtualmachine/${VM_NAME}" -n "${VM_NAMESPACE}" 1>/dev/null
}

EnsureNamespace
CreateS3Secret
ApplyDataVolume
printf 'Waiting for DataVolume %s on spoke %s to become Ready\n' "${dvName}" "${P2P_HS_SPOKE_INDEX}" >&2
SpokeOc wait "datavolume/${dvName}" -n "${VM_NAMESPACE}" --for=condition=Ready --timeout=45m
ApplyVirtualMachine
printf 'Waiting for VirtualMachine %s on spoke %s to become Ready\n' "${VM_NAME}" "${P2P_HS_SPOKE_INDEX}" >&2
SpokeOc wait "vm/${VM_NAME}" -n "${VM_NAMESPACE}" --for=condition=Ready --timeout=15m
SpokeOc wait "vmi/${VM_NAME}" -n "${VM_NAMESPACE}" --for=jsonpath='{.status.phase}'=Running --timeout=15m

# Phase and Ready only. The full VMI object includes the node name and guest
# addresses, which must not be written to the CI log or the status artifact.
typeset vmiPhase vmiReady
vmiPhase="$(SpokeOc get "vmi/${VM_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.phase}')"
vmiReady="$(SpokeOc get "vmi/${VM_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
printf 'VMI %s phase=%s ready=%s\n' "${VM_NAME}" "${vmiPhase}" "${vmiReady}" >&2
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    printf 'name=%s\nphase=%s\nready=%s\n' "${VM_NAME}" "${vmiPhase}" "${vmiReady}" > "${ARTIFACT_DIR}/vmi-status.yaml"
fi

printf '%s\n' "${VM_NAME}" > "${SHARED_DIR}/windows-vm-name"
printf '%s\n' "${P2P_HS_SPOKE_INDEX}" > "${SHARED_DIR}/windows-vm-spoke-index"
printf 'Wrote VM name to %s/windows-vm-name (spoke %s)\n' "${SHARED_DIR}" "${P2P_HS_SPOKE_INDEX}" >&2
