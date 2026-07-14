#!/bin/bash
#
# Create MTV NetworkMap and StorageMap for vSphere → OpenShift Virtualization migration (CI step).
#
# Different from p2p-mtv-create-migration-maps (which targets OCP-to-OCP CCLM):
#   NetworkMap: maps vSphere portgroup → OCP pod network (destination spoke)
#   StorageMap: maps vSphere datastore (by MoRef ID) → ODF StorageClass on spoke
#
# Inputs from SHARED_DIR (written by p2p-create-vsphere-test-vms):
#   vsphere-datastore-id    — vSphere datastore MoRef ID (e.g. "datastore-10")
#   vsphere-portgroup-id    — vSphere portgroup MoRef ID (e.g. "dvportgroup-120")
#
# Hub kubeconfig is KUBECONFIG from ci-operator.
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

# =====================
# Input validation
# =====================
[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]
[[ -f "${SHARED_DIR}/vsphere-datastore-id" ]]
[[ -f "${SHARED_DIR}/vsphere-portgroup-id" ]]

typeset datastoreId portgroupId
datastoreId="$(< "${SHARED_DIR}/vsphere-datastore-id")"
portgroupId="$(< "${SHARED_DIR}/vsphere-portgroup-id")"
[[ -n "${datastoreId}" ]]
[[ -n "${portgroupId}" ]]

oc get ns "${MTV_NAMESPACE}" 1>/dev/null

# =====================
# Wait for both providers to be Ready before creating maps
# =====================
WaitProviderReady() {
    typeset providerName="${1:?}"
    oc wait "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${P2P_MTV_VSPHERE_MAP_PROVIDER_TIMEOUT}"
}

WaitProviderReady "${P2P_MTV_VSPHERE_SOURCE_PROVIDER}"
WaitProviderReady "${P2P_MTV_VSPHERE_DEST_PROVIDER}"

# Trigger inventory refresh so map validation uses current data
RefreshProviderInventory() {
    typeset providerName="${1:?}"
    typeset ts
    ts="$(date -u +%s)"
    oc annotate "provider/${providerName}" -n "${MTV_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

RefreshProviderInventory "${P2P_MTV_VSPHERE_SOURCE_PROVIDER}"
RefreshProviderInventory "${P2P_MTV_VSPHERE_DEST_PROVIDER}"

# =====================
# NetworkMap: vSphere portgroup → OCP pod network
#
# The source references the portgroup by MoRef ID from the vSphere Provider inventory.
# The destination type "pod" maps to the default pod network on the OCP spoke.
# =====================
jq -n \
    --arg name      "${P2P_MTV_VSPHERE_NETWORK_MAP_NAME}" \
    --arg ns        "${MTV_NAMESPACE}" \
    --arg srcProv   "${P2P_MTV_VSPHERE_SOURCE_PROVIDER}" \
    --arg dstProv   "${P2P_MTV_VSPHERE_DEST_PROVIDER}" \
    --arg pgId      "${portgroupId}" \
    '{
        apiVersion: "forklift.konveyor.io/v1beta1",
        kind: "NetworkMap",
        metadata: {name: $name, namespace: $ns},
        spec: {
            map: [{
                source:      {id: $pgId},
                destination: {type: "pod"}
            }],
            provider: {
                source:      {name: $srcProv, namespace: $ns},
                destination: {name: $dstProv, namespace: $ns}
            }
        }
    }' | {
    oc create -f - --dry-run=client -o yaml --save-config
} | oc apply -f -

# =====================
# StorageMap: vSphere datastore → ODF StorageClass on spoke
#
# The source references the datastore by MoRef ID from the vSphere Provider inventory.
# The destination uses the ODF virtualization StorageClass on the OCP spoke.
# =====================
jq -n \
    --arg name      "${P2P_MTV_VSPHERE_STORAGE_MAP_NAME}" \
    --arg ns        "${MTV_NAMESPACE}" \
    --arg srcProv   "${P2P_MTV_VSPHERE_SOURCE_PROVIDER}" \
    --arg dstProv   "${P2P_MTV_VSPHERE_DEST_PROVIDER}" \
    --arg dsId      "${datastoreId}" \
    --arg dstClass  "${P2P_MTV_VSPHERE_DEST_STORAGE_CLASS}" \
    '{
        apiVersion: "forklift.konveyor.io/v1beta1",
        kind: "StorageMap",
        metadata: {name: $name, namespace: $ns},
        spec: {
            map: [{
                source:      {id: $dsId},
                destination: {storageClass: $dstClass}
            }],
            provider: {
                source:      {name: $srcProv, namespace: $ns},
                destination: {name: $dstProv, namespace: $ns}
            }
        }
    }' | {
    oc create -f - --dry-run=client -o yaml --save-config
} | oc apply -f -

# =====================
# Wait for maps to reach Ready
# =====================
WaitMapReady() {
    typeset kind="${1:?}"
    typeset name="${2:?}"
    oc wait "${kind}/${name}" -n "${MTV_NAMESPACE}" \
        --for=condition=Ready --timeout="${P2P_MTV_VSPHERE_MAP_READY_TIMEOUT}"
}

WaitMapReady networkmap "${P2P_MTV_VSPHERE_NETWORK_MAP_NAME}"
WaitMapReady storagemap "${P2P_MTV_VSPHERE_STORAGE_MAP_NAME}"

# =====================
# Artifacts
# =====================
oc get networkmap,storagemap -n "${MTV_NAMESPACE}" \
    > "${ARTIFACT_DIR}/mtv-vsphere-migration-maps-status.txt"

: "NetworkMap ${P2P_MTV_VSPHERE_NETWORK_MAP_NAME} and StorageMap ${P2P_MTV_VSPHERE_STORAGE_MAP_NAME} are Ready"
true
