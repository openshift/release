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
    echo "[INFO] Loaded ${#clusters_to_uninstall[@]} cluster(s) from managed-cluster-names" >&2
elif [[ -f "${SHARED_DIR}/managed-cluster-name-1" ]]; then
    typeset idx=1
    while [[ -f "${SHARED_DIR}/managed-cluster-name-${idx}" ]]; do
        clusters_to_uninstall+=("$(cat "${SHARED_DIR}/managed-cluster-name-${idx}")")
        ((++idx))
    done
    echo "[INFO] Loaded ${#clusters_to_uninstall[@]} cluster(s) from managed-cluster-name-{N} files" >&2
elif [[ -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    clusters_to_uninstall=("$(cat "${SHARED_DIR}/managed-cluster-name")")
    echo "[INFO] Loaded 1 cluster from managed-cluster-name (single-cluster mode)" >&2
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
managed_cluster_json="$(oc get managedcluster -o json || echo '{"items":[]}')"
typeset -a all_spokes=()
mapfile -t all_spokes < <(echo "${managed_cluster_json}" | jq -r '.items[]? | select(.metadata.name!="local-cluster") | .metadata.name')
if [[ ${#all_spokes[@]} -gt 0 ]]; then
    echo "[INFO] Spoke ManagedClusters currently registered on hub: ${all_spokes[*]}" >&2
fi

typeset timeout_minutes="60"
typeset poll_seconds="10"
typeset force_delete_mc="false"

#=====================
# Helper functions
#=====================
Need() {
    command -v "$1" 1>/dev/null || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
    true
}

PickLatestDeprovName() {
    typeset namespace="$1"
    typeset deprov_json
    deprov_json="$(oc -n "${namespace}" get clusterdeprovisions -o json || echo '{"items":[]}')"
    echo "${deprov_json}" | jq -r '.items | sort_by(.metadata.creationTimestamp) | last? | .metadata.name // ""'
}

#=====================
# UninstallCluster - Uninstall a single spoke cluster
#=====================
UninstallCluster() {
    typeset cluster_name="$1"
    typeset namespace="${cluster_name}"

    echo "[INFO] Uninstalling cluster '${cluster_name}' in namespace '${namespace}'" >&2

    # Check if namespace exists
    if ! oc get ns "${namespace}" 1>/dev/null; then
        echo "[WARN] Namespace '${namespace}' not found; cluster may already be removed. Cleaning up cluster-scoped resources if they remain." >&2
        oc delete managedcluster "${cluster_name}" --ignore-not-found=true
        typeset mc_set_orphan="${cluster_name}-set"
        oc delete managedclusterset "${mc_set_orphan}" --ignore-not-found=true
        return 0
    fi

    # Detach from ACM (ManagedCluster) and clean up Klusterlet config
    echo "[INFO] Detaching from ACM (ManagedCluster) and cleaning up Klusterlet config for '${cluster_name}'" >&2
    if oc get managedcluster "${cluster_name}" 1>/dev/null; then
        echo "[INFO] Deleting ManagedCluster '${cluster_name}' from ACM (this is the primary deletion step)" >&2
        if [[ "${force_delete_mc}" == "true" ]]; then
            echo "[WARN] Force deleting ManagedCluster finalizers (if any)" >&2
            oc patch managedcluster "${cluster_name}" --type=merge -p '{"metadata":{"finalizers":null}}'
        fi
        oc delete managedcluster "${cluster_name}" --ignore-not-found=true
    else
        echo "[INFO] ManagedCluster '${cluster_name}' not present (already removed)" >&2
    fi

    if oc -n "${namespace}" get klusterletaddonconfig "${cluster_name}" 1>/dev/null; then
        echo "[INFO] Deleting KlusterletAddonConfig '${cluster_name}'" >&2
        oc -n "${namespace}" delete klusterletaddonconfig "${cluster_name}" --ignore-not-found=true
    fi

    # Ensure ClusterDeployment triggers infrastructure deprovisioning
    echo "[INFO] Ensuring ClusterDeployment triggers infrastructure deprovisioning for '${cluster_name}'" >&2
    typeset deprov_name=""
    # need_deprov_wait is true when Hive is (or will be) running a ClusterDeprovision:
    #   - We just deleted the ClusterDeployment → Hive will create a ClusterDeprovision shortly
    #   - ClusterDeployment was already gone but a ClusterDeprovision object exists → wait for it
    # It is false only when ClusterDeployment is already gone AND no ClusterDeprovision exists,
    # which means infrastructure was already cleaned up.
    typeset need_deprov_wait="false"

    if oc -n "${namespace}" get clusterdeployment "${cluster_name}" 1>/dev/null; then
        echo "[INFO] Patching ClusterDeployment '${cluster_name}' to ensure preserveOnDelete=false" >&2
        oc -n "${namespace}" patch clusterdeployment "${cluster_name}" --type=merge -p '{"spec":{"preserveOnDelete":false}}'
        echo "[INFO] Deleting ClusterDeployment '${cluster_name}' to initiate deprovisioning" >&2
        oc -n "${namespace}" delete clusterdeployment "${cluster_name}" --wait=false
        # deprov_name is still "" here; the inner poll loop below will wait for Hive
        # to create the ClusterDeprovision object before waiting for its completion.
        need_deprov_wait="true"
    else
        echo "[INFO] ClusterDeployment '${cluster_name}' already gone, checking for existing ClusterDeprovision." >&2
        deprov_name="$(PickLatestDeprovName "${namespace}")"
        if [[ -z "${deprov_name}" ]]; then
            echo "[INFO] No ClusterDeprovision found for '${cluster_name}'; infrastructure already cleaned up, skipping deprovision wait." >&2
        else
            echo "[INFO] Found existing ClusterDeprovision '${deprov_name}', waiting for completion." >&2
            need_deprov_wait="true"
        fi
    fi

    if [[ "${need_deprov_wait}" == "true" ]]; then
        echo "[INFO] Watching deprovision progress for '${cluster_name}'" >&2
        typeset start_time
        start_time="$(date +%s)"
        typeset deadline
        deadline=$((start_time + timeout_minutes * 60))

        # Poll until Hive creates the ClusterDeprovision object (only needed when we just
        # deleted the ClusterDeployment; skipped immediately when deprov_name is already set).
        echo "[INFO] Waiting for ClusterDeprovision object to be created for '${cluster_name}'..." >&2
        while [[ -z "${deprov_name}" ]]; do
            deprov_name="$(PickLatestDeprovName "${namespace}")"
            if [[ -n "${deprov_name}" ]]; then
                echo "[INFO] Found ClusterDeprovision: ${deprov_name}" >&2
                break
            fi
            if (( $(date +%s) > deadline )); then
                echo "[ERROR] Timeout waiting for ClusterDeprovision object creation for '${cluster_name}'." >&2
                return 3
            fi
            sleep "${poll_seconds}"
        done

        echo "[INFO] Waiting for ClusterDeprovision '${deprov_name}'.status.completed=true (timeout=${timeout_minutes}m)" >&2
        oc -n "${namespace}" wait \
            --for=jsonpath='{.status.completed}'=true \
            "clusterdeprovision/${deprov_name}" \
            --timeout="${timeout_minutes}m"

        echo "[INFO] Cluster '${cluster_name}' deprovisioning completed successfully." >&2
    fi

    # Remove binding before ManagedClusterSet (install creates ManagedClusterSetBinding in namespace)
    typeset mc_set_name="${cluster_name}-set"
    if oc -n "${namespace}" get managedclustersetbinding "${mc_set_name}" 1>/dev/null; then
        echo "[INFO] Deleting ManagedClusterSetBinding '${mc_set_name}' in namespace '${namespace}'" >&2
        oc -n "${namespace}" delete managedclustersetbinding "${mc_set_name}" --ignore-not-found=true --wait=false
    fi

    # Delete ManagedClusterSet (cluster-scoped, created per cluster)
    if oc get managedclusterset "${mc_set_name}" 1>/dev/null; then
        echo "[INFO] Deleting ManagedClusterSet '${mc_set_name}'" >&2
        oc delete managedclusterset "${mc_set_name}" --ignore-not-found=true
    fi

    true
}

Need oc
Need jq

#=====================
# Uninstall all clusters
#=====================
echo "[INFO] Uninstalling ${#clusters_to_uninstall[@]} spoke cluster(s): ${clusters_to_uninstall[*]}" >&2

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

echo "[INFO] All ${#clusters_to_uninstall[@]} spoke cluster(s) deprovisioned successfully." >&2
true
