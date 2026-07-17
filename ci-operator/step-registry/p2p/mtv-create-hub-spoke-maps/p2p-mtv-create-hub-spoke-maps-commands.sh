#!/bin/bash
#
# Create MTV NetworkMap and StorageMap for hub↔spoke migration on the ACM hub.
#
# Hub→Spoke direction: MTV_HS_HUB_TO_SPOKE_* env vars.
#   Source = MTV hub "host" provider (the hub cluster itself).
#   Destination = spoke OpenShift provider registered via p2p-mtv-register-providers.
#
# Spoke→Hub direction: MTV_HS_SPOKE_TO_HUB_* env vars.
#   Source = spoke OpenShift provider.
#   Destination = MTV hub "host" provider.
#
# The hub "host" provider is auto-created by MTV at install time and represents the
# local hub cluster. No separate registration is needed for it.
#
# Requires p2p-mtv-register-providers (spoke provider Ready) and ODF Available on
# both hub and spoke before this step.
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

# --- Main ---

oc get ns "${MTV_NAMESPACE}" 1>/dev/null

# Wait for both hub (host) and spoke providers to be Ready.
WaitProviderReady "${MTV_HS_HUB_PROVIDER}"
WaitProviderReady "${MTV_HS_SPOKE_PROVIDER}"

# Optionally refresh provider inventory so StorageMap validation uses current state.
if [[ "${MTV_HS_SKIP_INVENTORY_REFRESH}" != "true" ]]; then
    RefreshProviderInventory "${MTV_HS_HUB_PROVIDER}"
    RefreshProviderInventory "${MTV_HS_SPOKE_PROVIDER}"
fi

# Hub→Spoke direction maps.
ApplyNetworkMap "${MTV_HS_HUB_TO_SPOKE_NETWORK_MAP}" \
    "${MTV_HS_HUB_PROVIDER}" "${MTV_HS_SPOKE_PROVIDER}"
ApplyStorageMap "${MTV_HS_HUB_TO_SPOKE_STORAGE_MAP}" \
    "${MTV_HS_HUB_PROVIDER}" "${MTV_HS_SPOKE_PROVIDER}" \
    "${MTV_HS_HUB_STORAGE_NAME}" "${MTV_HS_SPOKE_STORAGE_CLASS}"

# Spoke→Hub direction maps.
ApplyNetworkMap "${MTV_HS_SPOKE_TO_HUB_NETWORK_MAP}" \
    "${MTV_HS_SPOKE_PROVIDER}" "${MTV_HS_HUB_PROVIDER}"
ApplyStorageMap "${MTV_HS_SPOKE_TO_HUB_STORAGE_MAP}" \
    "${MTV_HS_SPOKE_PROVIDER}" "${MTV_HS_HUB_PROVIDER}" \
    "${MTV_HS_SPOKE_STORAGE_NAME}" "${MTV_HS_HUB_STORAGE_CLASS}"

# Wait for all four maps to be Ready.
WaitMapReady networkmap "${MTV_HS_HUB_TO_SPOKE_NETWORK_MAP}"
WaitMapReady storagemap "${MTV_HS_HUB_TO_SPOKE_STORAGE_MAP}"
WaitMapReady networkmap "${MTV_HS_SPOKE_TO_HUB_NETWORK_MAP}"
WaitMapReady storagemap "${MTV_HS_SPOKE_TO_HUB_STORAGE_MAP}"

oc get networkmap,storagemap -n "${MTV_NAMESPACE}" \
    > "${ARTIFACT_DIR}/mtv-hub-spoke-maps-status.txt"

true
