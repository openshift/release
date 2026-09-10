#!/bin/bash
#
# Create MTV NetworkMap and StorageMap for bi-directional migration on the ACM hub.
#
# Supports hub↔spoke and spoke↔spoke topologies via generalized or legacy env vars:
#
#   Generalized (topology-agnostic, preferred for spoke-spoke):
#     MTV_SRC_PROVIDER / MTV_DST_PROVIDER       — forward direction src / dst provider names
#     MTV_FWD_NETWORK_MAP / MTV_FWD_STORAGE_MAP — forward direction map names
#     MTV_REV_NETWORK_MAP / MTV_REV_STORAGE_MAP — reverse direction map names
#     MTV_SRC_STORAGE_NAME / MTV_DST_STORAGE_CLASS — forward direction storage mapping
#     MTV_DST_STORAGE_NAME / MTV_SRC_STORAGE_CLASS — reverse direction storage mapping
#
#   Legacy hub↔spoke names (backward-compatible, used when generalized names are absent):
#     MTV_HS_HUB_PROVIDER / MTV_HS_SPOKE_PROVIDER
#     MTV_HS_HUB_TO_SPOKE_* / MTV_HS_SPOKE_TO_HUB_*
#     MTV_HS_HUB_STORAGE_NAME / MTV_HS_SPOKE_STORAGE_CLASS (etc.)
#
# Requires p2p-mtv-register-providers (providers Ready) and ODF Available on
# both clusters before this step.
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

# RefreshProviderInventory — trigger MTV to re-scan cluster inventory.
RefreshProviderInventory() {
    typeset providerName="${1:?}"
    typeset ts

    ts="$(date -u +%s)"
    oc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# WaitProviderReady — gate until MTV Provider is Ready.
WaitProviderReady() {
    typeset providerName="${1:?}"

    oc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_PROVIDER_READY_TIMEOUT}"
}

# ApplyNetworkMap — create pod→pod NetworkMap for cross-cluster pod networking.
ApplyNetworkMap() {
    typeset mapName="${1:?}"
    typeset srcProvider="${2:?}"
    typeset dstProvider="${3:?}"

    jq -n \
        --arg name    "${mapName}" \
        --arg ns      "${MTV_NAMESPACE}" \
        --arg srcProv "${srcProvider}" \
        --arg dstProv "${dstProvider}" \
        '{
            apiVersion: "forklift.konveyor.io/v1beta1",
            kind: "NetworkMap",
            metadata: {name: $name, namespace: $ns},
            spec: {
                map: [{source: {type: "pod"}, destination: {type: "pod"}}],
                provider: {
                    source:      {name: $srcProv, namespace: $ns},
                    destination: {name: $dstProv, namespace: $ns}
                }
            }
        }' | oc apply -f -
}

# ApplyStorageMap — map source ODF StorageClass to destination StorageClass.
ApplyStorageMap() {
    typeset mapName="${1:?}"
    typeset srcProvider="${2:?}"
    typeset dstProvider="${3:?}"
    typeset srcStorageName="${4:?}"
    typeset dstStorageClass="${5:?}"

    jq -n \
        --arg name     "${mapName}" \
        --arg ns       "${MTV_NAMESPACE}" \
        --arg srcProv  "${srcProvider}" \
        --arg dstProv  "${dstProvider}" \
        --arg srcName  "${srcStorageName}" \
        --arg dstClass "${dstStorageClass}" \
        '{
            apiVersion: "forklift.konveyor.io/v1beta1",
            kind: "StorageMap",
            metadata: {name: $name, namespace: $ns},
            spec: {
                map: [{
                    source:      {name: $srcName},
                    destination: {storageClass: $dstClass}
                }],
                provider: {
                    source:      {name: $srcProv, namespace: $ns},
                    destination: {name: $dstProv, namespace: $ns}
                }
            }
        }' | oc apply -f -
}

# WaitMapReady — wait until MTV validates the map against provider inventory.
WaitMapReady() {
    typeset kind="${1:?}"
    typeset name="${2:?}"

    oc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_HS_MAP_READY_TIMEOUT}"
}

# --- Resolve generalized env var aliases (fall back to legacy hub/spoke names) ---

# Forward direction: source cluster → destination cluster.
typeset _fwdSrcProv="${MTV_SRC_PROVIDER:-${MTV_HS_HUB_PROVIDER}}"
typeset _fwdDstProv="${MTV_DST_PROVIDER:-${MTV_HS_SPOKE_PROVIDER}}"
typeset _fwdNetMap="${MTV_FWD_NETWORK_MAP:-${MTV_HS_HUB_TO_SPOKE_NETWORK_MAP}}"
typeset _fwdStorMap="${MTV_FWD_STORAGE_MAP:-${MTV_HS_HUB_TO_SPOKE_STORAGE_MAP}}"
typeset _fwdSrcStorName="${MTV_SRC_STORAGE_NAME:-${MTV_HS_HUB_STORAGE_NAME}}"
typeset _fwdDstStorClass="${MTV_DST_STORAGE_CLASS:-${MTV_HS_SPOKE_STORAGE_CLASS}}"
# Reverse direction: destination cluster → source cluster.
typeset _revSrcProv="${MTV_REV_SRC_PROVIDER:-${MTV_HS_SPOKE_PROVIDER}}"
typeset _revDstProv="${MTV_REV_DST_PROVIDER:-${MTV_HS_HUB_PROVIDER}}"
typeset _revNetMap="${MTV_REV_NETWORK_MAP:-${MTV_HS_SPOKE_TO_HUB_NETWORK_MAP}}"
typeset _revStorMap="${MTV_REV_STORAGE_MAP:-${MTV_HS_SPOKE_TO_HUB_STORAGE_MAP}}"
typeset _revSrcStorName="${MTV_DST_STORAGE_NAME:-${MTV_HS_SPOKE_STORAGE_NAME}}"
typeset _revDstStorClass="${MTV_SRC_STORAGE_CLASS:-${MTV_HS_HUB_STORAGE_CLASS}}"

# --- Main ---

oc get ns "${MTV_NAMESPACE}" 1>/dev/null

# Wait for both providers to be Ready.
WaitProviderReady "${_fwdSrcProv}"
WaitProviderReady "${_fwdDstProv}"

# Optionally refresh provider inventory so StorageMap validation uses current state.
if [[ "${MTV_HS_SKIP_INVENTORY_REFRESH}" != "true" ]]; then
    RefreshProviderInventory "${_fwdSrcProv}"
    RefreshProviderInventory "${_fwdDstProv}"
fi

# Forward direction maps (e.g. hub→spoke or spoke-1→spoke-2).
ApplyNetworkMap "${_fwdNetMap}" "${_fwdSrcProv}" "${_fwdDstProv}"
ApplyStorageMap "${_fwdStorMap}" "${_fwdSrcProv}" "${_fwdDstProv}" \
    "${_fwdSrcStorName}" "${_fwdDstStorClass}"

# Reverse direction maps (e.g. spoke→hub or spoke-2→spoke-1).
ApplyNetworkMap "${_revNetMap}" "${_revSrcProv}" "${_revDstProv}"
ApplyStorageMap "${_revStorMap}" "${_revSrcProv}" "${_revDstProv}" \
    "${_revSrcStorName}" "${_revDstStorClass}"

# Wait for all four maps to be Ready.
WaitMapReady networkmap "${_fwdNetMap}"
WaitMapReady storagemap "${_fwdStorMap}"
WaitMapReady networkmap "${_revNetMap}"
WaitMapReady storagemap "${_revStorMap}"

oc get networkmap,storagemap -n "${MTV_NAMESPACE}" \
    > "${ARTIFACT_DIR}/mtv-hub-spoke-maps-status.txt"

true
