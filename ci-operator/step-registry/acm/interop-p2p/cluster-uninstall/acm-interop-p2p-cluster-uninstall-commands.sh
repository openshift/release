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

#=====================
# Load cluster names to uninstall (must run first; do not gate on hub API)
# Install writes managed-cluster-names, managed-cluster-name-{N}, and managed-cluster-name
#=====================
# Prefer managed-cluster-names (multi-cluster), then indexed files, then managed-cluster-name (single-cluster)
typeset -a clusters_to_uninstall=()
if [[ -f "${SHARED_DIR}/managed-cluster-names" ]]; then
    mapfile -t clusters_to_uninstall < <(grep -v '^[[:space:]]*$' "${SHARED_DIR}/managed-cluster-names" || true)
    echo "[INFO] Loaded ${#clusters_to_uninstall[@]} cluster(s) from managed-cluster-names"
elif [[ -f "${SHARED_DIR}/managed-cluster-name-1" ]]; then
    typeset idx=1
    while [[ -f "${SHARED_DIR}/managed-cluster-name-${idx}" ]]; do
        clusters_to_uninstall+=("$(cat "${SHARED_DIR}/managed-cluster-name-${idx}")")
        ((++idx))
    done
    echo "[INFO] Loaded ${#clusters_to_uninstall[@]} cluster(s) from managed-cluster-name-{N} files"
elif [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    clusters_to_uninstall=("$(cat "${SHARED_DIR}/managed-cluster-name")")
    echo "[INFO] Loaded 1 cluster from managed-cluster-name (single-cluster mode)"
else
    echo "[ERROR] No cluster name file found. Expected one of: managed-cluster-names, managed-cluster-name-1, or managed-cluster-name" >&2
    exit 1
fi

if [[ ${#clusters_to_uninstall[@]} -eq 0 ]]; then
    echo "[ERROR] No cluster names to uninstall" >&2
    exit 1
fi

# Diagnostics only: listing hub spokes can differ from file list (e.g. API already cleared)
typeset managed_cluster_json
managed_cluster_json="$(oc get managedcluster -o json 2>/dev/null || echo '{"items":[]}')"
typeset -a all_spokes=()
mapfile -t all_spokes < <(echo "${managed_cluster_json}" | jq -r '.items[]? | select(.metadata.name!="local-cluster") | .metadata.name')
if [[ ${#all_spokes[@]} -gt 0 ]]; then
    echo "[INFO] Spoke ManagedClusters currently registered on hub: ${all_spokes[*]}"
fi

timeout_minutes="60"  # Default deprovisioning timeout per cluster
poll_seconds="10"     # Polling interval for checks
force_delete_mc="false"

#=====================
# Helper functions
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
    true
}

PickLatestDeprovName() {
    typeset namespace="$1"
    typeset deprov_json
    deprov_json="$(oc -n "${namespace}" get clusterdeprovisions -o json 2>/dev/null || echo '{"items":[]}')"
    echo "${deprov_json}" | jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""'
}

#=====================
# UninstallCluster - Uninstall a single spoke cluster
#=====================
UninstallCluster() {
    typeset cluster_name="$1"
    typeset namespace="${cluster_name}"

    echo "[INFO] Uninstalling cluster '${cluster_name}' in namespace '${namespace}'"

    # Check if namespace exists
    if ! oc get ns "${namespace}" >/dev/null 2>&1; then
        echo "[WARN] Namespace '${namespace}' not found; cluster may already be removed. Cleaning up cluster-scoped resources if they remain." >&2
        oc delete managedcluster "${cluster_name}" --ignore-not-found=true
        typeset mc_set_orphan="${cluster_name}-set"
        oc delete managedclusterset "${mc_set_orphan}" --ignore-not-found=true
        return 0
    fi

    # Detach from ACM (ManagedCluster) and clean up Klusterlet config
    echo "[INFO] Detaching from ACM (ManagedCluster) and cleaning up Klusterlet config for '${cluster_name}'"
    if oc get managedcluster "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting ManagedCluster '${cluster_name}' from ACM (this is the primary deletion step)"
        if [[ "${force_delete_mc}" == "true" ]]; then
            echo "[WARN] Force deleting ManagedCluster finalizers (if any)"
            oc patch managedcluster "${cluster_name}" --type=merge -p '{"metadata":{"finalizers":null}}'
        fi
        oc delete managedcluster "${cluster_name}" --ignore-not-found=true
    else
        echo "[INFO] ManagedCluster '${cluster_name}' not present (already removed)"
    fi

    if oc -n "${namespace}" get klusterletaddonconfig "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting KlusterletAddonConfig '${cluster_name}'"
        oc -n "${namespace}" delete klusterletaddonconfig "${cluster_name}" --ignore-not-found=true
    fi

    # Ensure ClusterDeployment triggers infrastructure deprovisioning
    echo "[INFO] Ensuring ClusterDeployment triggers infrastructure deprovisioning for '${cluster_name}'"
    typeset deprov_name=""
    if oc -n "${namespace}" get clusterdeployment "${cluster_name}" >/dev/null 2>&1; then
        echo "[INFO] Patching ClusterDeployment '${cluster_name}' to ensure preserveOnDelete=false"
        oc -n "${namespace}" patch clusterdeployment "${cluster_name}" --type=merge -p '{"spec":{"preserveOnDelete":false}}'
        echo "[INFO] Deleting ClusterDeployment '${cluster_name}' to initiate deprovisioning"
        oc -n "${namespace}" delete clusterdeployment "${cluster_name}" --wait=false
    else
        echo "[INFO] ClusterDeployment '${cluster_name}' already gone, checking for existing ClusterDeprovision."
        deprov_name="$(PickLatestDeprovName "${namespace}")"
        if [[ -z "${deprov_name}" ]]; then
            echo "[INFO] No ClusterDeprovision found for '${cluster_name}'; infrastructure already cleaned up, skipping deprovision wait."
        else
            echo "[INFO] Found existing ClusterDeprovision '${deprov_name}', waiting for completion."
        fi
    fi

    # Watch deprovision progress only when there is a ClusterDeprovision to track.
    # When deprov_name is empty (infrastructure already gone) we skip the wait and
    # fall through to the ManagedClusterSet/ManagedClusterSetBinding cleanup below.
    if [[ -n "${deprov_name}" ]]; then
        echo "[INFO] Watching deprovision progress for '${cluster_name}'"
        typeset start_time
        start_time="$(date +%s)"
        typeset deadline
        deadline=$((start_time + timeout_minutes * 60))

        echo "[INFO] Waiting for ClusterDeprovision object to be created for '${cluster_name}'..."
        while [[ -z "${deprov_name}" ]]; do
            deprov_name="$(PickLatestDeprovName "${namespace}")"
            if [[ -n "${deprov_name}" ]]; then
                echo "[INFO] Found ClusterDeprovision: ${deprov_name}"
                break
            fi
            if (( $(date +%s) > deadline )); then
                echo "[ERROR] Timeout waiting for ClusterDeprovision object creation for '${cluster_name}'." >&2
                return 3
            fi
            sleep "${poll_seconds}"
        done

        echo "[INFO] Waiting for ClusterDeprovision '${deprov_name}'.status.completed=true (timeout=${timeout_minutes}m)"
        oc -n "${namespace}" wait \
            --for=jsonpath='{.status.completed}'=true \
            "clusterdeprovision/${deprov_name}" \
            --timeout="${timeout_minutes}m"

        echo "[INFO] Cluster '${cluster_name}' deprovisioning completed successfully."
    fi

    # Remove binding before ManagedClusterSet (install creates ManagedClusterSetBinding in namespace)
    typeset mc_set_name="${cluster_name}-set"
    if oc -n "${namespace}" get managedclustersetbinding "${mc_set_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting ManagedClusterSetBinding '${mc_set_name}' in namespace '${namespace}'"
        oc -n "${namespace}" delete managedclustersetbinding "${mc_set_name}" --ignore-not-found=true --wait=false
    fi

    # Delete ManagedClusterSet (cluster-scoped, created per cluster)
    if oc get managedclusterset "${mc_set_name}" >/dev/null 2>&1; then
        echo "[INFO] Deleting ManagedClusterSet '${mc_set_name}'"
        oc delete managedclusterset "${mc_set_name}" --ignore-not-found=true
    fi

    true
}

Need oc
Need jq

#=====================
# Uninstall all clusters
#=====================
echo "[INFO] Uninstalling ${#clusters_to_uninstall[@]} spoke cluster(s): ${clusters_to_uninstall[*]}"

typeset failed=0
for cluster_name in "${clusters_to_uninstall[@]}"; do
    cluster_name="$(echo "${cluster_name}" | tr -d '\n\r')"
    if [[ -z "${cluster_name}" ]]; then
        continue
    fi
    if ! UninstallCluster "${cluster_name}"; then
        echo "[ERROR] Failed to uninstall cluster '${cluster_name}'" >&2
        ((failed++)) || true
    fi
done

if [[ "${failed}" -gt 0 ]]; then
    echo "[ERROR] ${failed} cluster(s) failed to uninstall" >&2
    exit 3
fi

echo "[INFO] All ${#clusters_to_uninstall[@]} spoke cluster(s) deprovisioned successfully."
true
