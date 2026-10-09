#!/bin/bash
#
# Discover and wait for the ACM-managed MTV Providers ("<managed-cluster>-mtv") that ACM's
# mtv-integrations controller creates automatically for ManagedClusters labeled
# acm/cnv-operator-install=true (see p2p-acm-cnv-addon-install). This step never creates
# Provider/Secret/ManifestWork objects itself — read-only discovery + readiness gating.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # Disable xtrace: proxy-conf.sh may set HTTP_PROXY with embedded credentials.
    typeset _wasTracing=false
    if [[ $- == *x* ]]; then _wasTracing=true; fi
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    [[ "${_wasTracing}" == "true" ]] && set -x
fi

typeset -a managedClusterNamesArr=()
typeset -a providerNamesArr=()

# ResolveSpokeInputs — build the array of ACM ManagedCluster names, 1-based index order,
# matching the index space used by managed-cluster-name-<N> / managed-cluster-kubeconfig-<N>.
ResolveSpokeInputs() {
    typeset -i i
    typeset mcList

    if [[ -n "${MTV_SPOKE_CLUSTER_NAMES}" ]]; then
        mcList="${MTV_SPOKE_CLUSTER_NAMES}"
        IFS=',' read -r -a managedClusterNamesArr <<< "${mcList}"
        for ((i = 0; i < ${#managedClusterNamesArr[@]}; i++)); do
            managedClusterNamesArr[i]="$(tr -d '[:space:]' <<< "${managedClusterNamesArr[i]}")"
            [[ -n "${managedClusterNamesArr[i]}" ]]
        done
        ((${#managedClusterNamesArr[@]} >= 1))
        return 0
    fi

    [[ -n "${SHARED_DIR}" ]]

    typeset -i spokeCount="${MTV_SPOKE_CLUSTER_COUNT}"
    ((spokeCount >= 1))

    for ((i = 1; i <= spokeCount; i++)); do
        if [[ -s "${SHARED_DIR}/managed-cluster-name-${i}" ]]; then
            managedClusterNamesArr+=("$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name-${i}")")
        elif (( i == 1 )) && [[ -s "${SHARED_DIR}/managed-cluster-name" ]]; then
            managedClusterNamesArr+=("$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")")
        else
            printf 'ERROR: managed-cluster-name-%d missing in SHARED_DIR\n' "${i}" >&2
            return 1
        fi
    done
}

# WaitManagedClusterAvailable — gate until ACM reports the spoke is joined and reachable.
WaitManagedClusterAvailable() {
    typeset mcName="${1:?}"
    oc wait "managedcluster/${mcName}" \
        --for=condition=ManagedClusterConditionAvailable \
        --timeout="${MTV_MANAGED_CLUSTER_WAIT_TIMEOUT}"
}

# WaitProviderCreated — poll until ACM's mtv-integrations controller has reconciled the
# Provider object for this managed cluster (reconciliation can lag the CNV add-on label).
WaitProviderCreated() {
    typeset providerName="${1:?}"
    oc wait "provider/${providerName}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=create --timeout="${MTV_PROVIDER_DISCOVERY_TIMEOUT}"
}

# WaitProviderReady — gate until the discovered Provider's inventory connection is Ready.
WaitProviderReady() {
    typeset providerName="${1:?}"
    oc wait "provider/${providerName}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_READY_TIMEOUT}"
}

# DiscoverOneSpoke — full per-spoke flow: ManagedCluster Available, derive the ACM provider
# name, wait for ACM to create + ready it, then publish the name for downstream steps.
DiscoverOneSpoke() {
    typeset index="${1:?}"
    typeset managedClusterName="${2:?}"
    typeset providerName="${managedClusterName}${MTV_ACM_PROVIDER_SUFFIX}"

    WaitManagedClusterAvailable "${managedClusterName}"
    WaitProviderCreated "${providerName}"
    WaitProviderReady "${providerName}"

    printf '%s' "${providerName}" > "${SHARED_DIR}/mtv-acm-provider-name-${index}"
    providerNamesArr+=("${providerName}")
}

# DumpDiagnostics — ACM-created provider state to ARTIFACT_DIR (best-effort, no secrets).
DumpDiagnostics() {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/mtv-wait-acm-providers-diagnostics"
    mkdir -p "${diagDir}"
    oc get provider -n "${MTV_PROVIDER_NAMESPACE}" -o wide \
        > "${diagDir}/providers.txt" 2>&1 || true
    oc get managedserviceaccount -A \
        > "${diagDir}/managedserviceaccounts.txt" 2>&1 || true
    oc get managedcluster -o wide \
        > "${diagDir}/managedclusters.txt" 2>&1 || true
}
trap DumpDiagnostics EXIT

# --- Main ---
[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

ResolveSpokeInputs

oc get ns "${MTV_PROVIDER_NAMESPACE}" 1>/dev/null

typeset -i stepRc=0
set +e
(
    set -e
    typeset -i i
    for ((i = 0; i < ${#managedClusterNamesArr[@]}; i++)); do
        DiscoverOneSpoke "$((i + 1))" "${managedClusterNamesArr[i]}"
    done
)
stepRc=$?
set -e

if (( stepRc != 0 )); then
    exit "${stepRc}"
fi

mkdir -p "${ARTIFACT_DIR}"
oc get providers -n "${MTV_PROVIDER_NAMESPACE}" \
    > "${ARTIFACT_DIR}/mtv-acm-providers-status.txt"
true
