#!/bin/bash
#
# Register ACM managed spokes as MTV OpenShift Providers on the hub (CI step).
# Hub: KUBECONFIG. Spoke RBAC via ManifestWork; token+cacert from Hive admin kubeconfig.
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

typeset -i spokeCount="${MTV_SPOKE_CLUSTER_COUNT}"

typeset -a providerNamesArr=()
typeset -a managedClusterNamesArr=()
typeset    tmpDir=""

# Cleanup — remove temp kubeconfig/token files on EXIT (never persist credentials).
Cleanup() {
    set +x
    [[ -n "${tmpDir}" && -d "${tmpDir}" ]] && rm -rf "${tmpDir}"
    true
}
trap Cleanup EXIT

# ResolveSpokeInputs — build parallel arrays of ACM cluster names and MTV Provider CR names.
# Reads MTV_SPOKE_CLUSTER_NAMES env or SHARED_DIR files from cluster-install; MTV_PROVIDER_NAMES
# can override CR names (e.g. spoke-1,spoke-2) while cluster names stay dynamic.
ResolveSpokeInputs() {
    typeset -i i
    typeset mcList provList

    if [[ -n "${MTV_SPOKE_CLUSTER_NAMES}" ]]; then
        mcList="${MTV_SPOKE_CLUSTER_NAMES}"
        if [[ -n "${MTV_PROVIDER_NAMES}" ]]; then
            provList="${MTV_PROVIDER_NAMES}"
        else
            provList="${MTV_SPOKE_CLUSTER_NAMES}"
        fi

        IFS=',' read -r -a managedClusterNamesArr <<< "${mcList}"
        IFS=',' read -r -a providerNamesArr <<< "${provList}"

        for ((i = 0; i < ${#managedClusterNamesArr[@]}; i++)); do
            managedClusterNamesArr[i]="$(tr -d '[:space:]' <<< "${managedClusterNamesArr[i]}")"
            providerNamesArr[i]="$(tr -d '[:space:]' <<< "${providerNamesArr[i]}")"
            [[ -n "${managedClusterNamesArr[i]}" && -n "${providerNamesArr[i]}" ]]
        done
        ((${#managedClusterNamesArr[@]} >= 1))
        ((${#providerNamesArr[@]} == ${#managedClusterNamesArr[@]}))
        return 0
    fi

    [[ -n "${SHARED_DIR}" ]]
    [[ -f "${KUBECONFIG}" ]]

    if (( spokeCount == 1 )); then
        [[ -f "${SHARED_DIR}/managed-cluster-name" ]]
        managedClusterNamesArr+=("$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")")
        [[ -n "${managedClusterNamesArr[0]}" ]]
        if [[ -n "${MTV_PROVIDER_NAME}" ]]; then
            # Explicit single-spoke override (MTV_PROVIDER_NAME takes precedence).
            providerNamesArr+=("$(tr -d '[:space:]' <<< "${MTV_PROVIDER_NAME}")")
        elif [[ -n "${MTV_PROVIDER_NAMES}" ]]; then
            # MTV_PROVIDER_NAMES (plural) also works for a single spoke — extract first entry.
            typeset _firstName
            IFS=',' read -r _firstName _ <<< "${MTV_PROVIDER_NAMES}"
            _firstName="$(tr -d '[:space:]' <<< "${_firstName}")"
            [[ -n "${_firstName}" ]]
            providerNamesArr+=("${_firstName}")
        else
            providerNamesArr+=("${managedClusterNamesArr[0]}")
        fi
        return 0
    fi

    for ((i = 1; i <= spokeCount; i++)); do
        [[ -f "${SHARED_DIR}/managed-cluster-name-${i}" ]]
        managedClusterNamesArr+=("$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name-${i}")")
    done

    if [[ -n "${MTV_PROVIDER_NAMES}" ]]; then
        IFS=',' read -r -a providerNamesArr <<< "${MTV_PROVIDER_NAMES}"
        for ((i = 0; i < ${#providerNamesArr[@]}; i++)); do
            providerNamesArr[i]="$(tr -d '[:space:]' <<< "${providerNamesArr[i]}")"
            [[ -n "${providerNamesArr[i]}" ]]
        done
        ((${#providerNamesArr[@]} == ${#managedClusterNamesArr[@]}))
    else
        for ((i = 0; i < ${#managedClusterNamesArr[@]}; i++)); do
            providerNamesArr+=("${managedClusterNamesArr[i]}")
        done
    fi
    true
}

# WaitManagedClusterAvailable — gate until ACM reports the spoke is joined and reachable.
WaitManagedClusterAvailable() {
    typeset mcName="${1:?}"
    oc wait "managedcluster/${mcName}" \
        --for=condition=ManagedClusterConditionAvailable \
        --timeout="${MTV_MANAGED_CLUSTER_WAIT_TIMEOUT}"
}

# SpokeApiUrlFromHub — read the spoke API URL from Hive ClusterDeployment status on the hub.
SpokeApiUrlFromHub() {
    typeset mcName="${1:?}"
    typeset apiUrl

    apiUrl="$(oc -n "${mcName}" get "ClusterDeployment/${mcName}" \
        -o jsonpath='{.status.apiURL}')"
    [[ -n "${apiUrl}" ]]
    printf '%s' "${apiUrl}"
}

# FetchSpokeAdminKubeconfigFromHub — extract admin kubeconfig from Hive secret (tracing disabled).
FetchSpokeAdminKubeconfigFromHub() {
    typeset mcName="${1:?}"
    typeset outFile="${2:?}"
    typeset secretName

    secretName="$(oc -n "${mcName}" get "ClusterDeployment/${mcName}" \
        -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')"
    [[ -n "${secretName}" ]]

    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    oc -n "${mcName}" get "secret/${secretName}" \
        -o jsonpath='{.data.kubeconfig}' | base64 -d > "${outFile}"
    [[ "${_wasTracing}" == "true" ]] && set -x
    [[ -s "${outFile}" ]]
}

# EnsureSpokeMtvSaViaManifestWork — push MTV namespace + provider SA/RBAC to spoke via ACM.
# Required so oc create token can mint credentials MTV uses to inventory the spoke cluster.
EnsureSpokeMtvSaViaManifestWork() {
    typeset mcName="${1:?}"

    {
        oc create -f - --dry-run=client -o yaml --save-config
    } <<EOF | oc apply -f -
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${MTV_MANIFESTWORK_NAME}
  namespace: ${mcName}
spec:
  deleteOption:
    propagationPolicy: Orphan
  workload:
    manifests:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: ${MTV_NAMESPACE}
    - apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: ${MTV_PROVIDER_SA_NAME}
        namespace: ${MTV_NAMESPACE}
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: ${MTV_PROVIDER_SA_NAME}-admin
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: cluster-admin
      subjects:
      - kind: ServiceAccount
        name: ${MTV_PROVIDER_SA_NAME}
        namespace: ${MTV_NAMESPACE}
EOF

    oc wait "manifestwork/${MTV_MANIFESTWORK_NAME}" -n "${mcName}" \
        --for=condition=Applied --timeout="${MTV_MANIFESTWORK_TIMEOUT}"
    oc wait "manifestwork/${MTV_MANIFESTWORK_NAME}" -n "${mcName}" \
        --for=condition=Available --timeout="${MTV_MANIFESTWORK_TIMEOUT}"
}

# MintSpokeMtvCredentials — create SA token and cluster CA cert for the Provider secret (no log leak).
MintSpokeMtvCredentials() {
    typeset spokeKubeconfig="${1:?}"
    typeset tokenOut="${2:?}"
    typeset cacertOut="${3:?}"
    typeset token cacert
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    token="$(oc --kubeconfig="${spokeKubeconfig}" create token "${MTV_PROVIDER_SA_NAME}" \
        -n "${MTV_NAMESPACE}" --duration="${MTV_TOKEN_DURATION}")"
    token="$(tr -d '\n\r\t ' <<< "${token}")"
    [[ -n "${token}" ]]

    cacert="$(oc --kubeconfig="${spokeKubeconfig}" get configmap kube-root-ca.crt \
        -n kube-public -o jsonpath='{.data.ca\.crt}')"
    [[ -n "${cacert}" ]]
    printf '%s' "${token}" > "${tokenOut}"
    printf '%s' "${cacert}" > "${cacertOut}"
    [[ "${_wasTracing}" == "true" ]] && set -x
}

# CreateProviderSecretOnHub — idempotently apply token+cacert secret referenced by the Provider CR.
CreateProviderSecretOnHub() {
    typeset providerName="${1:?}"
    typeset tokenFile="${2:?}"
    typeset cacertFile="${3:?}"
    typeset secretName="${providerName}-secret"
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    oc -n "${MTV_NAMESPACE}" create secret generic "${secretName}" \
        --from-literal=token="$(<"${tokenFile}")" \
        --from-file=cacert="${cacertFile}" \
        --dry-run=client -o yaml --save-config | oc apply -f - 1>/dev/null
    [[ "${_wasTracing}" == "true" ]] && set -x
}

# CreateProviderOnHub — apply forklift Provider CR and wait until inventory connection is Ready.
CreateProviderOnHub() {
    typeset providerName="${1:?}"
    typeset apiUrl="${2:?}"
    typeset secretName="${3:?}"

    {
        oc create -f - --dry-run=client -o yaml --save-config
    } <<EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: ${providerName}
  namespace: ${MTV_NAMESPACE}
spec:
  type: openshift
  url: ${apiUrl}
  secret:
    name: ${secretName}
    namespace: ${MTV_NAMESPACE}
EOF

    oc -n "${MTV_NAMESPACE}" wait "provider/${providerName}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_READY_TIMEOUT}"
}

# RegisterOneSpoke — full per-spoke flow: RBAC, credentials, secret, Provider CR, Ready wait.
RegisterOneSpoke() {
    typeset providerName="${1:?}"
    typeset managedClusterName="${2:?}"
    typeset apiUrl secretName kcFile tokenFile cacertFile

    WaitManagedClusterAvailable "${managedClusterName}"
    apiUrl="$(SpokeApiUrlFromHub "${managedClusterName}")"
    EnsureSpokeMtvSaViaManifestWork "${managedClusterName}"

    kcFile="${tmpDir}/${providerName}-admin.kubeconfig"
    FetchSpokeAdminKubeconfigFromHub "${managedClusterName}" "${kcFile}"

    tokenFile="${tmpDir}/${providerName}.token"
    cacertFile="${tmpDir}/${providerName}.cacert"
    MintSpokeMtvCredentials "${kcFile}" "${tokenFile}" "${cacertFile}"

    secretName="${providerName}-secret"
    CreateProviderSecretOnHub "${providerName}" "${tokenFile}" "${cacertFile}"
    CreateProviderOnHub "${providerName}" "${apiUrl}" "${secretName}"

    rm -f "${tokenFile}" "${cacertFile}" "${kcFile}"
}

# --- Main ---
[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

ResolveSpokeInputs

tmpDir="$(mktemp -d)"

oc get ns "${MTV_NAMESPACE}" 1>/dev/null

typeset -i i
for ((i = 0; i < ${#providerNamesArr[@]}; i++)); do
    RegisterOneSpoke "${providerNamesArr[i]}" "${managedClusterNamesArr[i]}"
done

oc get providers -n "${MTV_NAMESPACE}" \
    > "${ARTIFACT_DIR}/mtv-providers-status.txt"
true
