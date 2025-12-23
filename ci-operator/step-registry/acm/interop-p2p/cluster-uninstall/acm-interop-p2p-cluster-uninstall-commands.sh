#!/bin/bash
#
# ACM Spoke Cluster Uninstall Script
#
# Uninstalls one or more ACM spoke clusters by deleting ManagedCluster,
# ClusterDeployment, and related resources. Reads cluster names from SHARED_DIR
# (same files cluster-install writes); hub API is not used to decide what to remove:
#   - managed-cluster-names (preferred, one name per line for multi-cluster)
#   - managed-cluster-name-{N} (indexed files from cluster-install)
#   - managed-cluster-name (fallback for single-cluster backward compatibility)
#

set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

trap '(($?)) || exit 0
    oc get managedcluster -o wide \
        > "${ARTIFACT_DIR}/managed-clusters-on-failure.txt" || true
    oc get clusterdeprovision -A \
        > "${ARTIFACT_DIR}/deprovisions-on-failure.txt" || true
' EXIT

#=====================
# Load cluster names to uninstall (must run first; do not gate on hub API)
# Install writes managed-cluster-names, managed-cluster-name-{N}, and managed-cluster-name
#=====================
# Prefer managed-cluster-names (multi-cluster), then indexed files, then managed-cluster-name (single-cluster)
typeset -a clustersToUninstallArr=()
if [[ -f "${SHARED_DIR}/managed-cluster-names" ]]; then
    mapfile -t clustersToUninstallArr < <(grep -v '^[[:space:]]*$' "${SHARED_DIR}/managed-cluster-names" || true)
    : "Loaded ${#clustersToUninstallArr[@]} cluster(s) from managed-cluster-names"
elif [[ -f "${SHARED_DIR}/managed-cluster-name-1" ]]; then
    typeset -i idx=1
    while [[ -f "${SHARED_DIR}/managed-cluster-name-${idx}" ]]; do
        clustersToUninstallArr+=("$(< "${SHARED_DIR}/managed-cluster-name-${idx}")")
        (( ++idx ))
    done
    : "Loaded ${#clustersToUninstallArr[@]} cluster(s) from managed-cluster-name-{N} files"
elif [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    clustersToUninstallArr=("$(< "${SHARED_DIR}/managed-cluster-name")")
    : "Loaded 1 cluster from managed-cluster-name (single-cluster mode)"
else
    : "No cluster name file found. Expected one of: managed-cluster-names, managed-cluster-name-1, or managed-cluster-name"
    exit 1
fi

: "Resolved ${#clustersToUninstallArr[@]} cluster(s) to uninstall"
[[ ${#clustersToUninstallArr[@]} -gt 0 ]]

# Diagnostics only: listing hub spokes can differ from file list (e.g. API already cleared)
typeset managedClusterJson
managedClusterJson="$(oc get managedcluster -o json || printf '%s' '{"items":[]}')"
typeset -a allSpokesArr=()
mapfile -t allSpokesArr < <(
    jq -r '.items[]? | select(.metadata.name!="local-cluster") | .metadata.name' \
        <<< "${managedClusterJson}"
)
if [[ ${#allSpokesArr[@]} -gt 0 ]]; then
    : "Spoke ManagedClusters currently registered on hub: ${allSpokesArr[*]}"
fi

#=====================
# Helper functions
#=====================
# PickLatestDeprovName — return the most-recently-created ClusterDeprovision name
# in a namespace, or empty string when none exists.
PickLatestDeprovName() {
    typeset namespace="$1"
    typeset deprovJson
    deprovJson="$(oc -n "${namespace}" get clusterdeprovisions -o json || printf '%s' '{"items":[]}')"
    jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""' \
        <<< "${deprovJson}"
    true
}

#=====================
# UninstallCluster - Uninstall a single spoke cluster
#=====================
UninstallCluster() {
    typeset clusterName="$1"
    typeset namespace="${clusterName}"
    typeset -i timeoutSecs=$(( ACM_CLUSTER_DEPROVISION_TIMEOUT_MINUTES * 60 ))
    typeset -i pollSecs="${ACM_CLUSTER_DEPROVISION_POLL_SECONDS}"

    : "Uninstalling cluster '${clusterName}' in namespace '${namespace}'"

    # If namespace is gone, cluster may already be removed; clean up cluster-scoped resources
    if ! oc get ns "${namespace}" 1>/dev/null; then
        : "Namespace '${namespace}' not found; cluster may already be removed. Cleaning up cluster-scoped resources if they remain."
        oc delete managedcluster "${clusterName}" --ignore-not-found=true
        typeset mcSetOrphan="${clusterName}-set"
        oc delete managedclusterset "${mcSetOrphan}" --ignore-not-found=true
        return 0
    fi

    # Detach from ACM (ManagedCluster)
    : "Detaching from ACM (ManagedCluster) for '${clusterName}'"
    if oc get managedcluster "${clusterName}" 1>/dev/null; then
        : "Deleting ManagedCluster '${clusterName}' from ACM (primary deletion step)"
        if [[ "${ACM_CLUSTER_UNINSTALL_FORCE_DELETE_MC}" == "true" ]]; then
            : "Force-stripping finalizers from ManagedCluster '${clusterName}'"
            oc patch managedcluster "${clusterName}" \
                --type=merge -p '{"metadata":{"finalizers":null}}'
        fi
        oc delete managedcluster "${clusterName}" --ignore-not-found=true
    else
        : "ManagedCluster '${clusterName}' not present (already removed)"
    fi

    if oc -n "${namespace}" get klusterletaddonconfig "${clusterName}" 1>/dev/null; then
        : "Deleting KlusterletAddonConfig '${clusterName}'"
        oc -n "${namespace}" delete klusterletaddonconfig "${clusterName}" --ignore-not-found=true
    fi

    # Ensure ClusterDeployment triggers infrastructure deprovisioning
    : "Ensuring ClusterDeployment triggers infrastructure deprovisioning for '${clusterName}'"
    typeset deprovName=""
    # needDeprovWait is true when Hive is (or will be) running a ClusterDeprovision:
    #   - We just deleted the ClusterDeployment → Hive will create a ClusterDeprovision shortly
    #   - ClusterDeployment was already gone but a ClusterDeprovision object exists → wait for it
    # It is false only when ClusterDeployment is already gone AND no ClusterDeprovision exists,
    # which means infrastructure was already cleaned up.
    typeset needDeprovWait="false"

    if oc -n "${namespace}" get clusterdeployment "${clusterName}" 1>/dev/null; then
        : "Patching ClusterDeployment '${clusterName}' to ensure preserveOnDelete=false"
        oc -n "${namespace}" patch clusterdeployment "${clusterName}" \
            --type=merge -p '{"spec":{"preserveOnDelete":false}}'
        : "Deleting ClusterDeployment '${clusterName}' to initiate deprovisioning"
        oc -n "${namespace}" delete clusterdeployment "${clusterName}" --wait=false
        needDeprovWait="true"
    else
        : "ClusterDeployment '${clusterName}' already gone; checking for existing ClusterDeprovision"
        deprovName="$(PickLatestDeprovName "${namespace}")"
        if [[ -z "${deprovName}" ]]; then
            : "No ClusterDeprovision for '${clusterName}'; infrastructure already cleaned up"
        else
            : "Found existing ClusterDeprovision '${deprovName}'; waiting for completion"
            needDeprovWait="true"
        fi
    fi

    if [[ "${needDeprovWait}" == "true" ]]; then
        : "Watching deprovision progress for '${clusterName}'"

        # Poll until Hive creates the ClusterDeprovision object.
        # Skipped immediately when deprovName is already set above.
        if [[ -z "${deprovName}" ]]; then
            : "Waiting for ClusterDeprovision object to appear for '${clusterName}'"
            deprovName="$(
                SECONDS=0
                while (( SECONDS < timeoutSecs )); do
                    typeset found
                    found="$(PickLatestDeprovName "${namespace}")"
                    if [[ -n "${found}" ]]; then
                        : "Found ClusterDeprovision: ${found}"
                        printf '%s' "${found}"
                        exit 0
                    fi
                    : "Waiting for ClusterDeprovision (${SECONDS}/${timeoutSecs}s)"
                    sleep "${pollSecs}"
                done
                exit 1
            )" || {
                : "Timeout: no ClusterDeprovision appeared for '${clusterName}' after ${timeoutSecs}s"
                false
            }
        fi

        : "Waiting for ClusterDeprovision '${deprovName}'.status.completed=true (timeout=${ACM_CLUSTER_DEPROVISION_TIMEOUT_MINUTES}m)"
        oc -n "${namespace}" wait \
            --for=jsonpath='{.status.completed}'=true \
            "clusterdeprovision/${deprovName}" \
            --timeout="${ACM_CLUSTER_DEPROVISION_TIMEOUT_MINUTES}m"

        : "Cluster '${clusterName}' deprovisioning completed"
    fi

    # Remove binding before ManagedClusterSet (install creates ManagedClusterSetBinding in namespace)
    typeset mcSetName="${clusterName}-set"
    if oc -n "${namespace}" get managedclustersetbinding "${mcSetName}" 1>/dev/null; then
        : "Deleting ManagedClusterSetBinding '${mcSetName}' in namespace '${namespace}'"
        oc -n "${namespace}" delete managedclustersetbinding "${mcSetName}" \
            --ignore-not-found=true --wait=false
    fi

    # Delete ManagedClusterSet (cluster-scoped, created per cluster)
    if oc get managedclusterset "${mcSetName}" 1>/dev/null; then
        : "Deleting ManagedClusterSet '${mcSetName}'"
        oc delete managedclusterset "${mcSetName}" --ignore-not-found=true
    fi

    true
}

command -v oc 1>/dev/null || { : "oc not found"; exit 1; }

#=====================
# Uninstall all clusters
#=====================
: "Uninstalling ${#clustersToUninstallArr[@]} spoke cluster(s): ${clustersToUninstallArr[*]}"

typeset -i failedCount=0
for clusterName in "${clustersToUninstallArr[@]}"; do
    clusterName="$(printf '%s' "${clusterName}" | tr -d '\n\r')"
    [[ -z "${clusterName}" ]] && continue
    if ! UninstallCluster "${clusterName}"; then
        : "Failed to uninstall cluster '${clusterName}'"
        (( failedCount++ )) || true
    fi
done

if [[ "${failedCount}" -gt 0 ]]; then
    : "${failedCount} cluster(s) failed to uninstall"
    exit 3
fi

: "All ${#clustersToUninstallArr[@]} spoke cluster(s) deprovisioned successfully"
true
