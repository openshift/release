#!/bin/bash
#
# Create MTV NetworkMap and StorageMap on the hub (CI step).
# Requires registered MTV providers and ODF Available on both spokes.
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



# ValidateConfig — fail fast if storage map env vars are missing.
ValidateConfig() {
    [[ -n "${MTV_SOURCE_STORAGE_NAME}" ]]    || { : "MTV_SOURCE_STORAGE_NAME is required";    false; }
    [[ -n "${MTV_DESTINATION_STORAGE_CLASS}" ]] || { : "MTV_DESTINATION_STORAGE_CLASS is required"; false; }
}

# RefreshProviderInventory — trigger MTV to re-scan spoke storage/network before map validation.
RefreshProviderInventory() {
    typeset providerName="${1:?}"
    typeset ts

    ts="$(date -u +%s)"
    oc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# WaitProviderReady — ensure both providers finished inventory before creating maps.
WaitProviderReady() {
    typeset providerName="${1:?}"

    oc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_READY_TIMEOUT}"
}

# ApplyNetworkMap — create pod→pod NetworkMap for CCLM cross-cluster pod networking.
# Uses jq --arg to safely marshal values; avoids raw heredoc expansion of YAML-special chars.
ApplyNetworkMap() {
    jq -n \
        --arg name    "${MTV_NETWORK_MAP_NAME}" \
        --arg ns      "${MTV_NAMESPACE}" \
        --arg srcProv "${MTV_SOURCE_PROVIDER}" \
        --arg dstProv "${MTV_DESTINATION_PROVIDER}" \
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

# ApplyStorageMap — map source ODF virt StorageClass to destination (RWX required for live migration).
# Uses jq --arg to safely marshal values; avoids raw heredoc expansion of YAML-special chars.
ApplyStorageMap() {
    jq -n \
        --arg name     "${MTV_STORAGE_MAP_NAME}" \
        --arg ns       "${MTV_NAMESPACE}" \
        --arg srcName  "${MTV_SOURCE_STORAGE_NAME}" \
        --arg dstClass "${MTV_DESTINATION_STORAGE_CLASS}" \
        --arg srcProv  "${MTV_SOURCE_PROVIDER}" \
        --arg dstProv  "${MTV_DESTINATION_PROVIDER}" \
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

# WaitMapReady — wait until MTV validates network/storage mapping against provider inventory.
WaitMapReady() {
    typeset kind="${1:?}"
    typeset name="${2:?}"

    oc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_MAP_READY_TIMEOUT}"
}

# --- Main ---
[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

ValidateConfig

oc get ns "${MTV_NAMESPACE}" 1>/dev/null

WaitProviderReady "${MTV_SOURCE_PROVIDER}"
WaitProviderReady "${MTV_DESTINATION_PROVIDER}"

if [[ "${MTV_SKIP_INVENTORY_REFRESH}" != "true" ]]; then
    RefreshProviderInventory "${MTV_SOURCE_PROVIDER}"
    RefreshProviderInventory "${MTV_DESTINATION_PROVIDER}"
fi

ApplyNetworkMap
ApplyStorageMap

WaitMapReady networkmap "${MTV_NETWORK_MAP_NAME}"
WaitMapReady storagemap "${MTV_STORAGE_MAP_NAME}"

oc get networkmap,storagemap -n "${MTV_NAMESPACE}" \
    > "${ARTIFACT_DIR}/mtv-migration-maps-status.txt"
true
